#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# mqvpn-entrypoint — prepare and supervise the mqvpn server inside Docker.
#
# Replaces upstream's systemd unit + mqvpn-server-setup + mqvpn-server-nat.sh
# (none of which can run in a container) with the same steps:
#   1. validate the environment (.env)
#   2. create the auth key and TLS certificate once, persist them in the
#      /etc/mqvpn volume, never regenerate them, never log them
#   3. render /run/mqvpn/server.conf from the environment on every start
#   4. IP forwarding + NAT/MASQUERADE in dedicated, idempotent firewall chains
#   5. run `mqvpn --config ...` as an unprivileged user that keeps only
#      CAP_NET_ADMIN and CAP_NET_BIND_SERVICE
#   6. watchdog: repair firewall rules, restart on a dead TUN/event loop
#   7. on SIGTERM: stop mqvpn, remove the firewall rules, restore sysctls

# shellcheck disable=SC2034  # many variables are consumed via state_write
set -Eeuo pipefail
umask 077
LOG_TAG=entrypoint
# shellcheck source=common.sh
. /usr/local/lib/mqvpn-docker/common.sh

MQVPN_PID=
MQVPN_RC=
STOPPING=0
FW_ACTIVE=0
WATCHDOG_INTERVAL=30

# ---------------------------------------------------------------------------
# Signal handling and cleanup
# ---------------------------------------------------------------------------

# alive PID: true while the process runs (a zombie counts as gone)
alive() {
    local st
    st=$(sed -n 's/^.*) \([A-Za-z]\).*/\1/p' "/proc/$1/stat" 2>/dev/null) || return 1
    [ -n "$st" ] && [ "$st" != Z ] && [ "$st" != X ]
}

# reap_mqvpn TIMEOUT_S: wait for mqvpn to exit (SIGKILL after TIMEOUT_S) and
# store its exit status in MQVPN_RC.
reap_mqvpn() {
    local timeout=$1 i
    [ -n "$MQVPN_PID" ] || return 0
    for (( i = 0; i < timeout * 5; i++ )); do
        alive "$MQVPN_PID" || break
        sleep 0.2
    done
    if alive "$MQVPN_PID"; then
        warn "mqvpn did not stop within ${timeout}s; killing it"
        kill -KILL "$MQVPN_PID" 2>/dev/null || true
    fi
    MQVPN_RC=0
    # The process is gone (or a zombie) now, so wait returns at once; repeat
    # if a trapped signal interrupted it.
    for (( i = 0; i < 50; i++ )); do
        wait "$MQVPN_PID" 2>/dev/null && { MQVPN_RC=0; break; }
        MQVPN_RC=$?
        [ "$MQVPN_RC" -eq 127 ] && break
        alive "$MQVPN_PID" || break
        sleep 0.1
    done
    MQVPN_PID=
}

on_signal() {
    STOPPING=1
    if [ -z "$MQVPN_PID" ]; then
        info "stop requested during startup"
        exit 143
    fi
    if alive "$MQVPN_PID"; then
        info "stopping mqvpn (pid $MQVPN_PID)"
        kill -TERM "$MQVPN_PID" 2>/dev/null || true
    fi
}

cleanup() {
    local rc=$?
    trap - EXIT
    trap '' TERM INT
    set +e
    if [ -n "$MQVPN_PID" ]; then
        alive "$MQVPN_PID" && kill -TERM "$MQVPN_PID" 2>/dev/null
        reap_mqvpn 10
    fi
    rm -f "$READY_FILE" "$PID_FILE"
    if [ "$FW_ACTIVE" = 1 ]; then
        /usr/local/bin/mqvpn-firewall teardown || err "firewall teardown failed"
    fi
    sysctl_restore
    exit "$rc"
}

trap on_signal TERM INT
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Configuration from the environment
# ---------------------------------------------------------------------------

read_env() {
    PORT=$(env_int MQVPN_PORT 443 1 65535)

    LISTEN_ADDR=${MQVPN_LISTEN_ADDR:-0.0.0.0}
    if valid_ip4 "$LISTEN_ADDR"; then
        LISTEN="$LISTEN_ADDR:$PORT"
    elif valid_ip6 "$LISTEN_ADDR"; then
        LISTEN="[$LISTEN_ADDR]:$PORT"
    else
        die "MQVPN_LISTEN_ADDR must be an IPv4 or IPv6 address (got '$LISTEN_ADDR')"
    fi

    SUBNET=${MQVPN_SUBNET:-10.70.0.0/24}
    valid_subnet4 "$SUBNET" \
        || die "MQVPN_SUBNET must be an IPv4 network address with a /16../30 prefix, e.g. 10.70.0.0/24 (got '$SUBNET')"

    SUBNET6_MODE=${MQVPN_SUBNET6:-auto}
    case "${SUBNET6_MODE,,}" in
        auto|off) SUBNET6_MODE=${SUBNET6_MODE,,} ;;
        *) valid_subnet6 "$SUBNET6_MODE" \
               || die "MQVPN_SUBNET6 must be auto, off or an IPv6 prefix /96../126, e.g. fd12:3456:789a::/112 (got '$SUBNET6_MODE')" ;;
    esac

    TUN_NAME=${MQVPN_TUN_NAME:-mqvpn0}
    valid_ifname "$TUN_NAME" || die "MQVPN_TUN_NAME must be 1-15 characters [A-Za-z0-9_.-] (got '$TUN_NAME')"

    MTU=${MQVPN_MTU:-}
    if [ -n "$MTU" ] && [ "$MTU" != auto ]; then
        MTU=$(env_int MQVPN_MTU 0 1280 9000)
    else
        MTU=
    fi

    LOG_LEVEL=$(env_enum MQVPN_LOG_LEVEL info debug info warn error)
    MAX_CLIENTS=$(env_int MQVPN_MAX_CLIENTS 64 1 65535)
    SCHEDULER=$(env_enum MQVPN_SCHEDULER wlb wlb minrtt wlb_udp_pin backup_fec)
    ALLOW_CLIENT_SCHEDULER=$(env_bool MQVPN_ALLOW_CLIENT_SCHEDULER true)
    CC=$(env_enum MQVPN_CC bbr2 bbr2 bbr cubic)
    REINJECTION=$(env_enum MQVPN_REINJECTION off off deadline idle)
    HYBRID=$(env_bool MQVPN_HYBRID true)
    REORDER=$(env_bool MQVPN_REORDER true)

    CONTROL_PORT=$(env_int MQVPN_CONTROL_PORT 19090 0 65535)

    GLOBAL_KEY_ENABLED=$(env_bool MQVPN_GLOBAL_KEY true)
    USERS_RAW=${MQVPN_USERS:-}

    NAT_INTERFACE=${MQVPN_NAT_INTERFACE:-auto}
    if [ "$NAT_INTERFACE" != auto ] && [ "$NAT_INTERFACE" != any ]; then
        valid_ifname "$NAT_INTERFACE" || die "MQVPN_NAT_INTERFACE must be auto, any or an interface name (got '$NAT_INTERFACE')"
    fi
    BLOCK_PRIVATE=$(env_bool MQVPN_BLOCK_PRIVATE_NETWORKS true)
    OPEN_INPUT_PORT=$(env_bool MQVPN_FIREWALL_OPEN_PORT false)
    SKIP_SUBNET_CHECK=$(env_bool MQVPN_SKIP_SUBNET_CHECK false)

    PUBLIC_HOST=${MQVPN_PUBLIC_HOST:-}
    if [ -n "$PUBLIC_HOST" ] && ! [[ "$PUBLIC_HOST" =~ ^[A-Za-z0-9.:-]{1,253}$ ]]; then
        die "MQVPN_PUBLIC_HOST must be a hostname or IP address (got '$PUBLIC_HOST')"
    fi

    TLS_CERT_SRC=${MQVPN_TLS_CERT_FILE:-}
    TLS_KEY_SRC=${MQVPN_TLS_KEY_FILE:-}
}

# ---------------------------------------------------------------------------
# 2. Preflight checks
# ---------------------------------------------------------------------------

has_cap() { # has_cap BIT
    local eff
    eff=$(awk '/^CapEff:/ {print $2}' /proc/self/status)
    (( (16#$eff >> $1) & 1 ))
}

preflight() {
    [ "$(id -u)" -eq 0 ] || die "the entrypoint must start as root (it drops privileges for mqvpn itself)"
    has_cap 12 || die "CAP_NET_ADMIN is missing: add 'cap_add: [NET_ADMIN]' (see compose.yaml)"
    [ -c /dev/net/tun ] || die "/dev/net/tun is missing: add 'devices: [/dev/net/tun:/dev/net/tun]' (see compose.yaml); on the host run 'modprobe tun' if needed"

    mkdir -p "$DATA_DIR" "$RUN_DIR"
    chmod 0700 "$DATA_DIR"
    chown root:mqvpn "$RUN_DIR"
    chmod 0750 "$RUN_DIR"
    rm -f "$READY_FILE" "$PID_FILE" "$SYSCTL_RESTORE_FILE"

    # The device node inside the container is private to it; let the mqvpn
    # group open it (on some hosts it is 0600).
    chown root:mqvpn /dev/net/tun
    chmod 0660 /dev/net/tun

    if [ -e "/sys/class/net/$TUN_NAME" ]; then
        die "network interface $TUN_NAME already exists on this host: another mqvpn instance is probably running (container or systemd 'mqvpn-server'). Stop it or set MQVPN_TUN_NAME."
    fi

    IPT_BACKEND=$(detect_iptables_backend)
    ipt -t nat -n -L POSTROUTING >/dev/null 2>&1 \
        || die "iptables-$IPT_BACKEND does not work in this container (missing NET_ADMIN/NET_RAW, or the host kernel lacks the nat table)"
}

# ---------------------------------------------------------------------------
# 3. Networking: uplink, forwarding, IPv6, conflicts
# ---------------------------------------------------------------------------

setup_uplink() {
    local auto
    auto=$(detect_uplink4 || true)
    SRC4=$(detect_src4 || true)
    if [ "$NAT_INTERFACE" = auto ]; then
        [ -n "$auto" ] || die "cannot detect the outbound interface (no IPv4 default route?). Set MQVPN_NAT_INTERFACE to the interface name or 'any'."
        UPLINK4=$auto
    else
        UPLINK4=$NAT_INTERFACE
        if [ "$UPLINK4" != any ] && [ ! -e "/sys/class/net/$UPLINK4" ]; then
            die "MQVPN_NAT_INTERFACE=$UPLINK4 does not exist on this host"
        fi
    fi
    if [ -z "$PUBLIC_HOST" ]; then
        PUBLIC_HOST=${SRC4:-}
        PUBLIC_HOST_AUTO=1
    else
        PUBLIC_HOST_AUTO=0
    fi
}

ensure_ip_forward() {
    if [ "$(sysctl_get net/ipv4/ip_forward)" = 1 ]; then
        return 0
    fi
    if sysctl_set net/ipv4/ip_forward 1; then
        info "enabled net.ipv4.ip_forward (restored on shutdown)"
    else
        die "net.ipv4.ip_forward is 0 and cannot be changed from the container. Keep the '/proc/sys/net:/host/proc/sys/net' volume from compose.yaml, or on the host run: sysctl -w net.ipv4.ip_forward=1"
    fi
}

# IPv6 inside the tunnel. 'auto' enables it only when the host has working
# IPv6 egress; otherwise the tunnel is IPv4-only (clients then get no IPv6
# address from the server).
setup_ipv6() {
    SUBNET6=
    UPLINK6=
    IPV6_STATUS="disabled (MQVPN_SUBNET6=off)"
    [ "$SUBNET6_MODE" = off ] && return 0

    local reason='' want=$SUBNET6_MODE
    if [ ! -d /proc/sys/net/ipv6 ]; then
        reason="IPv6 is disabled in the host kernel"
    else
        UPLINK6=$(detect_uplink6 || true)
        local src6
        src6=$(detect_src6 || true)
        if [ -z "$UPLINK6" ] || [ -z "$src6" ] || [[ "${src6,,}" == fe80:* ]]; then
            reason="the host has no global IPv6 default route"
        elif ! ip6t -t nat -n -L POSTROUTING >/dev/null 2>&1; then
            reason="ip6tables-$IPT_BACKEND (nat table) is not usable"
        fi
    fi
    if [ -z "$reason" ] && [ "$(sysctl_get net/ipv6/conf/all/forwarding)" != 1 ]; then
        if host_sysctl_writable; then
            # With forwarding on, Linux ignores Router Advertisements unless
            # accept_ra=2. Keep a SLAAC-configured uplink working.
            if [ "$(sysctl_get "net/ipv6/conf/$UPLINK6/accept_ra")" = 1 ]; then
                sysctl_set "net/ipv6/conf/$UPLINK6/accept_ra" 2 \
                    && info "set net.ipv6.conf.$UPLINK6.accept_ra=2 so the host keeps its IPv6 router while forwarding"
            fi
            if sysctl_set net/ipv6/conf/all/forwarding 1; then
                info "enabled net.ipv6.conf.all.forwarding (restored on shutdown)"
            else
                reason="cannot enable net.ipv6.conf.all.forwarding"
            fi
        else
            reason="net.ipv6.conf.all.forwarding=0 and /proc/sys/net is not mounted writable"
        fi
    fi

    if [ -n "$reason" ]; then
        if [ "$want" = auto ]; then
            IPV6_STATUS="disabled ($reason)"
            UPLINK6=
            return 0
        fi
        die "MQVPN_SUBNET6=$want requested but $reason. Use MQVPN_SUBNET6=auto or off."
    fi

    if [ "$want" = auto ]; then
        # One random RFC 4193 ULA /112 per installation, kept in the volume.
        local f="$DATA_DIR/subnet6"
        if [ ! -s "$f" ]; then
            local hex
            hex=$(openssl rand -hex 5)
            printf 'fd%s:%s:%s::/112\n' "${hex:0:2}" "${hex:2:4}" "${hex:6:4}" > "$f.tmp"
            mv -f "$f.tmp" "$f"
        fi
        SUBNET6=$(head -n1 "$f")
        valid_subnet6 "$SUBNET6" || die "$f contains an invalid prefix; delete it to regenerate"
    else
        SUBNET6=$want
    fi
    if [ "$NAT_INTERFACE" = any ]; then UPLINK6=any; fi
    IPV6_STATUS="enabled ($SUBNET6 -> NAT66 via $UPLINK6)"
}

check_subnet_conflicts() {
    [ "$SKIP_SUBNET_CHECK" = true ] && return 0
    local mine my_s my_e cidr r s e len dev
    mine=$(cidr4_range "$SUBNET")
    my_s=${mine% *}; my_e=${mine#* }
    # Interface addresses and routes of the host (any table). Routes shorter
    # than /8 (default routes, 0/1 + 128/1 of a host VPN) are not conflicts:
    # the more specific tunnel route wins for its own subnet.
    while read -r cidr dev; do
        [ -n "$cidr" ] || continue
        [ "$dev" = "$TUN_NAME" ] && continue
        [[ "$cidr" == */* ]] && len=${cidr#*/} || len=32
        (( len >= 8 )) || continue
        r=$(cidr4_range "$cidr" 2>/dev/null) || continue
        s=${r% *}; e=${r#* }
        if (( s <= my_e && my_s <= e )); then
            die "MQVPN_SUBNET $SUBNET overlaps $cidr on interface ${dev:-?} of this host. Choose a free private range (e.g. 10.71.0.0/24) or set MQVPN_SKIP_SUBNET_CHECK=true if you are sure."
        fi
    done < <(
        ip -4 -o addr show 2>/dev/null | awk '{print $4, $2}'
        ip -4 route show table all type unicast 2>/dev/null \
            | awk '$1 != "default" { dev=""; for (i = 1; i < NF; i++) if ($i == "dev") dev = $(i + 1); print $1, dev }'
    )
}

check_port_conflicts() {
    local used
    # Sockets on the same UDP port clash unless both are bound to different
    # specific addresses.
    used=$(ss -Hlun "sport = :$PORT" 2>/dev/null | awk -v want="$LISTEN_ADDR" '
        { a = $4; sub(/:[0-9]+$/, "", a); gsub(/^\[|\]$/, "", a); sub(/%.*$/, "", a)
          wild_a = (a == "0.0.0.0" || a == "::" || a == "*")
          wild_w = (want == "0.0.0.0" || want == "::")
          if (wild_a || wild_w || a == want) print $4 }' | sort -u | tr '\n' ' ')
    if [ -n "$used" ]; then
        die "UDP port $PORT is already in use on this host ($used). On Dokploy hosts Traefik publishes UDP 443 for HTTP/3: set MQVPN_PORT to a free port (e.g. 8443) or free UDP $PORT. See README 'Port conflicts'."
    fi
    if "iptables-${IPT_BACKEND}-save" -t nat 2>/dev/null \
        | grep -E -- '-p udp .*--dport '"$PORT"'( |$).*-j DNAT' >/dev/null; then
        die "a Docker container publishes UDP port $PORT (DNAT rule in the nat table) and would capture the VPN traffic. Set MQVPN_PORT to a free port (e.g. 8443) or unpublish UDP $PORT. See README 'Port conflicts'."
    fi
    if [ "$CONTROL_PORT" != 0 ] && [ -n "$(ss -Hltn "sport = :$CONTROL_PORT" 2>/dev/null)" ]; then
        warn "TCP port $CONTROL_PORT (control API) is already in use; the control API and its health checks are disabled. Set MQVPN_CONTROL_PORT to a free port."
        CONTROL_PORT=0
    fi
}

# ---------------------------------------------------------------------------
# 4. Credentials (generated once, persisted, never logged)
# ---------------------------------------------------------------------------

valid_key() { [[ "$1" =~ ^[[:graph:]]{16,255}$ ]]; }

# gen_key_file PATH: create PATH with a fresh `mqvpn --genkey` key unless it
# already exists. ln(1) never replaces a file that appeared meanwhile.
gen_key_file() {
    local path=$1 tmp key
    [ -s "$path" ] && return 0
    tmp=$(mktemp "$(dirname "$path")/.key.XXXXXX")
    key=$("$MQVPN_BIN" --genkey) || { rm -f "$tmp"; die "mqvpn --genkey failed"; }
    valid_key "$key" || { rm -f "$tmp"; die "mqvpn --genkey returned an unexpected value"; }
    printf '%s\n' "$key" > "$tmp"
    chmod 0600 "$tmp"
    if ln "$tmp" "$path" 2>/dev/null; then
        info "generated a new auth key: $path (shown only by 'mqvpn-info --show-key')"
    fi
    rm -f "$tmp"
}

read_key_file() {
    local key
    key=$(head -n1 "$1" | tr -d '\r')
    valid_key "$key" || die "$1 does not contain a valid key (16-255 printable characters). Fix or delete it."
    printf '%s' "$key"
}

setup_auth() {
    GLOBAL_KEY=
    KEY_SOURCE=none
    if [ "$GLOBAL_KEY_ENABLED" = true ]; then
        if [ -n "${MQVPN_AUTH_KEY:-}" ]; then
            valid_key "$MQVPN_AUTH_KEY" || die "MQVPN_AUTH_KEY must be 16-255 printable characters without spaces (generate one with: docker run --rm --entrypoint mqvpn <image> --genkey)"
            GLOBAL_KEY=$MQVPN_AUTH_KEY
            KEY_SOURCE='env'
        else
            gen_key_file "$DATA_DIR/auth.key"
            GLOBAL_KEY=$(read_key_file "$DATA_DIR/auth.key")
            KEY_SOURCE='file'
        fi
    fi

    USER_NAMES=()
    USER_KEYS=()
    local name
    for name in ${USERS_RAW//,/ }; do
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] \
            || die "MQVPN_USERS: invalid user name '$name' (letters, digits, . _ - ; max 63)"
        local dup=0 n
        for n in "${USER_NAMES[@]}"; do [ "$n" = "$name" ] && dup=1; done
        [ "$dup" = 1 ] && continue
        mkdir -p "$DATA_DIR/users"
        chmod 0700 "$DATA_DIR/users"
        gen_key_file "$DATA_DIR/users/$name.key"
        USER_NAMES+=("$name")
        USER_KEYS+=("$(read_key_file "$DATA_DIR/users/$name.key")")
    done
    (( ${#USER_NAMES[@]} <= 64 )) || die "MQVPN_USERS: at most 64 users are supported"

    if [ -z "$GLOBAL_KEY" ] && (( ${#USER_NAMES[@]} == 0 )); then
        die "no credentials: MQVPN_GLOBAL_KEY=false requires at least one name in MQVPN_USERS"
    fi
}

# ---------------------------------------------------------------------------
# 5. TLS certificate
# ---------------------------------------------------------------------------

install_tls() { # install_tls CERT KEY -> copies readable by the mqvpn group
    mkdir -p "$RUN_DIR/tls"
    chown root:mqvpn "$RUN_DIR/tls"
    chmod 0750 "$RUN_DIR/tls"
    install -o root -g mqvpn -m 0640 "$1" "$RUN_DIR/tls/server.crt"
    install -o root -g mqvpn -m 0640 "$2" "$RUN_DIR/tls/server.key"
}

pubkey_digest() { # pubkey_digest x509|key FILE
    if [ "$1" = x509 ]; then
        openssl x509 -in "$2" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum
    else
        openssl pkey -in "$2" -pubout -outform DER 2>/dev/null | sha256sum
    fi
}

setup_tls() {
    local crt key
    if [ -n "$TLS_CERT_SRC" ] || [ -n "$TLS_KEY_SRC" ]; then
        [ -n "$TLS_CERT_SRC" ] && [ -n "$TLS_KEY_SRC" ] \
            || die "set both MQVPN_TLS_CERT_FILE and MQVPN_TLS_KEY_FILE (or neither for a self-signed certificate)"
        [ -r "$TLS_CERT_SRC" ] || die "MQVPN_TLS_CERT_FILE=$TLS_CERT_SRC is not readable in the container (mount it, see README)"
        [ -r "$TLS_KEY_SRC" ] || die "MQVPN_TLS_KEY_FILE=$TLS_KEY_SRC is not readable in the container (mount it, see README)"
        openssl x509 -in "$TLS_CERT_SRC" -noout 2>/dev/null || die "$TLS_CERT_SRC is not a PEM certificate"
        openssl pkey -in "$TLS_KEY_SRC" -noout 2>/dev/null || die "$TLS_KEY_SRC is not a PEM private key"
        [ "$(pubkey_digest x509 "$TLS_CERT_SRC")" = "$(pubkey_digest key "$TLS_KEY_SRC")" ] \
            || die "MQVPN_TLS_KEY_FILE does not match MQVPN_TLS_CERT_FILE"
        if ! openssl x509 -in "$TLS_CERT_SRC" -noout -checkend 0 >/dev/null 2>&1; then
            err "the TLS certificate $TLS_CERT_SRC has EXPIRED: clients that verify it will fail. Renew it and restart the container."
        elif ! openssl x509 -in "$TLS_CERT_SRC" -noout -checkend 1209600 >/dev/null 2>&1; then
            warn "the TLS certificate $TLS_CERT_SRC expires within 14 days; restart the container after renewal"
        fi
        crt=$TLS_CERT_SRC; key=$TLS_KEY_SRC
        TLS_MODE=custom
    else
        crt="$DATA_DIR/tls/server.crt"; key="$DATA_DIR/tls/server.key"
        mkdir -p "$DATA_DIR/tls"
        chmod 0700 "$DATA_DIR/tls"
        if [ -e "$crt" ] && [ -e "$key" ]; then
            :
        elif [ ! -e "$crt" ] && [ ! -e "$key" ]; then
            local cn=mqvpn san=() tmpk tmpc
            if [ -n "$PUBLIC_HOST" ] && [ "${PUBLIC_HOST_AUTO:-0}" = 0 ]; then
                cn=$PUBLIC_HOST
                if valid_ip4 "$PUBLIC_HOST" || valid_ip6 "$PUBLIC_HOST"; then
                    san=(-addext "subjectAltName=IP:$PUBLIC_HOST")
                else
                    san=(-addext "subjectAltName=DNS:$PUBLIC_HOST")
                fi
            fi
            tmpk=$(mktemp "$DATA_DIR/tls/.key.XXXXXX")
            tmpc=$(mktemp "$DATA_DIR/tls/.crt.XXXXXX")
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
                -keyout "$tmpk" -out "$tmpc" -days 3650 -nodes -subj "/CN=$cn" \
                "${san[@]}" >/dev/null 2>&1 \
                || { rm -f "$tmpk" "$tmpc"; die "failed to generate the self-signed certificate"; }
            chmod 0600 "$tmpk" "$tmpc"
            if ! ln "$tmpk" "$key" || ! ln "$tmpc" "$crt"; then
                rm -f "$tmpk" "$tmpc"
                die "certificate files appeared during setup; not replaced"
            fi
            rm -f "$tmpk" "$tmpc"
            info "generated a self-signed certificate (CN=$cn, valid 10 years) in $DATA_DIR/tls"
        else
            die "only one of $crt / $key exists. Restore the missing file or delete both to generate a new self-signed certificate."
        fi
        [ "$(pubkey_digest x509 "$crt")" = "$(pubkey_digest key "$key")" ] \
            || die "$key does not match $crt; delete both to regenerate"
        TLS_MODE=self-signed
    fi
    install_tls "$crt" "$key"
    TLS_FINGERPRINT=$(openssl x509 -in "$RUN_DIR/tls/server.crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
    TLS_SUBJECT=$(openssl x509 -in "$RUN_DIR/tls/server.crt" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')
    TLS_NOT_AFTER=$(openssl x509 -in "$RUN_DIR/tls/server.crt" -noout -enddate 2>/dev/null | cut -d= -f2)
}

# ---------------------------------------------------------------------------
# 6. server.conf (rendered on every start; secrets only in this 0640 file)
# ---------------------------------------------------------------------------

render_config() {
    local tmp i net extra="$DATA_DIR/server.extra.conf"
    tmp=$(mktemp "$RUN_DIR/.server.conf.XXXXXX")
    {
        echo "# Generated by mqvpn-entrypoint on every container start. Do not edit:"
        echo "# change .env instead, or put extra settings in $extra."
        echo "[Interface]"
        echo "Listen = $LISTEN"
        echo "Subnet = $SUBNET"
        [ -n "$SUBNET6" ] && echo "Subnet6 = $SUBNET6"
        echo "TunName = $TUN_NAME"
        echo "LogLevel = $LOG_LEVEL"
        [ -n "$MTU" ] && echo "MTU = $MTU"
        echo
        echo "[TLS]"
        echo "Cert = $RUN_DIR/tls/server.crt"
        echo "Key = $RUN_DIR/tls/server.key"
        echo
        echo "[Auth]"
        [ -n "$GLOBAL_KEY" ] && echo "Key = $GLOBAL_KEY"
        for i in "${!USER_NAMES[@]}"; do
            echo "User = ${USER_NAMES[$i]}:${USER_KEYS[$i]}"
        done
        echo "MaxClients = $MAX_CLIENTS"
        echo
        echo "[Multipath]"
        echo "Scheduler = $SCHEDULER"
        echo "AllowClientScheduler = $ALLOW_CLIENT_SCHEDULER"
        echo "CC = $CC"
        echo "Reinjection = $REINJECTION"
        echo
        # Server side only offers these; each is used only by clients that
        # enable it too (Android: "Carry TCP over its own lane", "Smooth out
        # packet order").
        echo "[Hybrid]"
        echo "Enabled = $HYBRID"
        if [ "$BLOCK_PRIVATE" = false ]; then
            # The hybrid TCP lane has its own default-deny list for private
            # destinations; open the same ranges the FORWARD rules allow.
            for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 fc00::/7; do
                echo "EgressAllow = $net"
            done
        fi
        echo
        echo "[Reorder]"
        echo "Enabled = $REORDER"
        if [ "$CONTROL_PORT" != 0 ]; then
            echo
            echo "[Control]"
            echo "Listen = 127.0.0.1:$CONTROL_PORT"
        fi
        if [ -s "$extra" ]; then
            echo
            echo "# ---- appended from $extra ----"
            cat "$extra"
        fi
    } > "$tmp"
    chown root:mqvpn "$tmp"
    chmod 0640 "$tmp"
    mv -f "$tmp" "$CONF_FILE"

    # Validate with upstream's own parser and read back the values the
    # firewall depends on (they may come from server.extra.conf).
    local parsed
    parsed=$("$NAT_CONFIG_BIN" "$CONF_FILE") \
        || die "the generated configuration is invalid (see the parser messages above; check .env and $extra)"
    local -a v
    mapfile -t v <<< "$parsed"
    if [ "${v[0]}" != "$SUBNET" ] || [ "${v[1]}" != "$SUBNET6" ] || [ "${v[2]}" != "$TUN_NAME" ]; then
        die "$extra must not change Subnet, Subnet6 or TunName; use MQVPN_SUBNET, MQVPN_SUBNET6 and MQVPN_TUN_NAME"
    fi
    if [ -s "$extra" ] && grep -qiE '^[[:space:]]*\[(Control)\]|^[[:space:]]*Listen[[:space:]]*=' "$extra"; then
        die "$extra must not set Listen or [Control]; use MQVPN_PORT, MQVPN_LISTEN_ADDR and MQVPN_CONTROL_PORT"
    fi
}

# ---------------------------------------------------------------------------
# 7. Run and supervise mqvpn
# ---------------------------------------------------------------------------

udp_port_bound() {
    [ -n "$(ss -Hlun "sport = :$PORT" 2>/dev/null)" ]
}

control_ok() {
    timeout 5 "$MQVPN_BIN" --status --control-addr 127.0.0.1 --control-port "$CONTROL_PORT" >/dev/null 2>&1
}

set_accept_local() {
    # mqvpn writes this itself but /proc/sys is read-only in containers (its
    # "cannot set accept_local" warning above is expected). Without it ICMP
    # errors (e.g. "fragmentation needed") for forwarded traffic are dropped.
    # Not recorded for restore: the setting disappears with the TUN device.
    local path="$HOST_SYSCTL_NET/ipv4/conf/$TUN_NAME/accept_local"
    if [ -w "$path" ] && printf 1 > "$path" 2>/dev/null; then
        info "set net.ipv4.conf.$TUN_NAME.accept_local=1 (the mqvpn warning about it can be ignored)"
    else
        warn "cannot set net.ipv4.conf.$TUN_NAME.accept_local (mount /proc/sys/net as in compose.yaml); Path MTU errors for forwarded traffic will be dropped"
    fi
}

start_mqvpn() {
    # cd /: the unprivileged process must not keep a root-only cwd.
    cd /
    # The hybrid TCP lane needs one descriptor per relayed TCP flow and sizes
    # its budget from the soft limit (Docker's default soft limit can be
    # 1024). Raising the soft limit up to the hard limit needs no privilege.
    local hard
    hard=$(ulimit -Hn)
    if [ "$hard" = unlimited ] || (( hard > 1048576 )); then hard=1048576; fi
    ulimit -Sn "$hard" 2>/dev/null || warn "could not raise the open-files limit (now $(ulimit -Sn))"
    setpriv --reuid=mqvpn --regid=mqvpn --clear-groups --no-new-privs \
        --inh-caps=-all,+net_admin,+net_bind_service \
        --ambient-caps=-all,+net_admin,+net_bind_service \
        -- "$MQVPN_BIN" --config "$CONF_FILE" &
    MQVPN_PID=$!
    echo "$MQVPN_PID" > "$PID_FILE"
    chmod 0644 "$PID_FILE"

    # The server creates the TUN and binds the UDP socket during startup. If
    # TUN creation fails it keeps running without one, so check explicitly.
    local i tun_ok=0 udp_ok=0
    for i in $(seq 1 75); do
        alive "$MQVPN_PID" || break
        [ "$tun_ok" = 0 ] && [ -e "/sys/class/net/$TUN_NAME" ] && tun_ok=1
        [ "$udp_ok" = 0 ] && udp_port_bound && udp_ok=1
        [ "$tun_ok" = 1 ] && [ "$udp_ok" = 1 ] && break
        sleep 0.2
    done
    if ! alive "$MQVPN_PID"; then
        reap_mqvpn 1
        [ "$STOPPING" = 1 ] && exit 0
        die "mqvpn exited during startup (exit code $MQVPN_RC); see its messages above"
    fi
    [ "$tun_ok" = 1 ] || die "mqvpn did not create TUN device $TUN_NAME (see 'TUN create failed' above); is /dev/net/tun usable?"
    [ "$udp_ok" = 1 ] || die "mqvpn is not listening on UDP port $PORT"

    set_accept_local

    CONTROL_OK=0
    if [ "$CONTROL_PORT" != 0 ]; then
        for i in $(seq 1 25); do
            if control_ok; then CONTROL_OK=1; break; fi
            sleep 0.2
        done
        [ "$CONTROL_OK" = 1 ] || warn "control API on 127.0.0.1:$CONTROL_PORT does not answer; health checks fall back to process/TUN/socket checks"
    fi
}

print_summary() {
    local addr=${PUBLIC_HOST:-<server-public-ip>}
    [[ "$addr" == *:* ]] && addr="[$addr]"
    info "mqvpn $("$MQVPN_BIN" --version | awk '{print $2}') server is up"
    info "  Android 'Server address' : $addr:$PORT  (UDP $PORT must be open in the VPS/cloud firewall)"
    if [ "${PUBLIC_HOST_AUTO:-0}" = 1 ]; then
        info "    (address auto-detected from the default route; set MQVPN_PUBLIC_HOST if clients use another IP or a DNS name)"
    fi
    info "  Android 'Access key'     : not logged; run 'mqvpn-info --show-key' in the container terminal"
    if [ "$TLS_MODE" = self-signed ]; then
        info "  TLS                      : self-signed -> turn ON 'Trust self-signed certificate' in the app"
    else
        info "  TLS                      : $TLS_SUBJECT (valid until $TLS_NOT_AFTER)"
    fi
    info "  Tunnel                   : IPv4 $SUBNET via $UPLINK4, IPv6 $IPV6_STATUS"
    info "  Users                    : global key $( [ -n "$GLOBAL_KEY" ] && echo "on ($KEY_SOURCE)" || echo off )${USER_NAMES[*]:+, per-user: ${USER_NAMES[*]}}"
}

save_state() {
    # Non-secret values for mqvpn-healthcheck / mqvpn-info / mqvpn-paths /
    # mqvpn-firewall.
    KEY_FILE_GLOBAL=$( [ "$KEY_SOURCE" = file ] && echo "$DATA_DIR/auth.key" || echo "" )
    USERS_LIST=${USER_NAMES[*]:-}
    state_write PORT LISTEN LISTEN_ADDR SUBNET SUBNET6 TUN_NAME UPLINK4 UPLINK6 \
        IPT_BACKEND BLOCK_PRIVATE OPEN_INPUT_PORT CONTROL_PORT CONTROL_OK \
        PUBLIC_HOST PUBLIC_HOST_AUTO TLS_MODE TLS_FINGERPRINT TLS_SUBJECT TLS_NOT_AFTER \
        IPV6_STATUS KEY_SOURCE KEY_FILE_GLOBAL USERS_LIST SCHEDULER CC HYBRID REORDER \
        MAX_CLIENTS NAT_INTERFACE
}

supervise() {
    local ctrl_failures=0 tun_failures=0 sleep_pid now_uplink fin st
    while :; do
        sleep "$WATCHDOG_INTERVAL" &
        sleep_pid=$!
        fin='' st=0
        wait -n -p fin "$MQVPN_PID" "$sleep_pid" 2>/dev/null || st=$?
        kill "$sleep_pid" 2>/dev/null || true
        wait "$sleep_pid" 2>/dev/null || true
        if [ "${fin:-}" = "$MQVPN_PID" ]; then
            # mqvpn exited and was reaped by wait -n
            MQVPN_RC=$st
            MQVPN_PID=
            return 0
        fi
        [ "$STOPPING" = 1 ] && return 0
        alive "$MQVPN_PID" || return 0

        # Outbound interface changed (e.g. network reconfiguration)?
        if [ "$NAT_INTERFACE" = auto ]; then
            now_uplink=$(detect_uplink4 || true)
            if [ -n "$now_uplink" ] && [ "$now_uplink" != "$UPLINK4" ]; then
                warn "outbound interface changed from $UPLINK4 to $now_uplink; updating NAT"
                UPLINK4=$now_uplink
                save_state
                /usr/local/bin/mqvpn-firewall setup || err "firewall update failed"
            fi
        fi

        # Rules removed by someone else (firewall reload, iptables -F, ...)?
        if ! /usr/local/bin/mqvpn-firewall check; then
            warn "firewall rules missing (host firewall reloaded?); re-applying"
            /usr/local/bin/mqvpn-firewall setup || err "firewall re-apply failed"
        fi

        if [ -e "/sys/class/net/$TUN_NAME" ]; then
            tun_failures=0
        else
            tun_failures=$((tun_failures + 1))
            err "TUN device $TUN_NAME disappeared ($tun_failures)"
            if (( tun_failures >= 2 )); then
                err "restarting: TUN device lost"
                kill -TERM "$MQVPN_PID" 2>/dev/null || true
                return 3
            fi
        fi

        if [ "$CONTROL_OK" = 1 ]; then
            if control_ok; then
                ctrl_failures=0
            else
                ctrl_failures=$((ctrl_failures + 1))
                warn "control API did not answer ($ctrl_failures/3)"
                if (( ctrl_failures >= 3 )); then
                    err "restarting: mqvpn event loop is not responding"
                    kill -TERM "$MQVPN_PID" 2>/dev/null || true
                    return 3
                fi
            fi
        fi
    done
}

main() {
    if [ "$#" -gt 0 ]; then
        # Allow one-off commands, e.g. `docker compose run --rm mqvpn mqvpn --genkey`
        exec "$@"
    fi

    read_env
    preflight
    setup_uplink
    ensure_ip_forward
    setup_ipv6
    check_subnet_conflicts
    check_port_conflicts
    setup_auth
    setup_tls
    render_config
    CONTROL_OK=0
    save_state

    # Set first: a partially applied setup is also cleaned up on exit.
    FW_ACTIVE=1
    /usr/local/bin/mqvpn-firewall setup

    start_mqvpn
    save_state
    touch "$READY_FILE"
    print_summary

    local sup_rc=0 rc
    supervise || sup_rc=$?

    # mqvpn exited by itself, was asked to stop, or the watchdog stopped it.
    reap_mqvpn 20
    rc=${MQVPN_RC:-0}
    if [ "$STOPPING" = 1 ]; then
        info "mqvpn stopped (exit code $rc)"
        exit 0
    fi
    [ "$sup_rc" != 0 ] && rc=$sup_rc
    err "mqvpn exited unexpectedly (exit code $rc); the container restart policy will start it again"
    exit $(( rc == 0 ? 1 : rc ))
}

main "$@"
