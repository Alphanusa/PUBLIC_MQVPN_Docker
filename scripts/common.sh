#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Shared helpers for the mqvpn container scripts. Sourced, never executed.
#
# Nothing in here prints secrets. Auth keys are only ever written to files with
# mode 0600/0640 and read back by mqvpn itself or by `mqvpn-info --show-key`.

# shellcheck disable=SC2034  # variables are used by the scripts sourcing this

MQVPN_BIN=/usr/local/bin/mqvpn
NAT_CONFIG_BIN=/usr/local/lib/mqvpn/mqvpn-nat-config
DATA_DIR=/etc/mqvpn
RUN_DIR=/run/mqvpn
CONF_FILE=$RUN_DIR/server.conf
STATE_FILE=$RUN_DIR/state.env
READY_FILE=$RUN_DIR/ready
PID_FILE=$RUN_DIR/mqvpn.pid
SYSCTL_RESTORE_FILE=$RUN_DIR/sysctl.restore
# /proc/sys is read-only inside containers. compose.yaml bind-mounts the host's
# /proc/sys/net here (writable) so forwarding sysctls can be managed.
HOST_SYSCTL_NET=${MQVPN_HOST_SYSCTL_NET:-/host/proc/sys/net}

LOG_TAG=${LOG_TAG:-mqvpn-docker}

log()  { printf '%s [%s] %s\n' "$(date -u +%H:%M:%S)" "$LOG_TAG" "$*" >&2; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*"; }
err()  { log "ERROR: $*"; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Environment parsing (all values are validated before use)
# ---------------------------------------------------------------------------

# env_bool NAME DEFAULT -> prints true|false
env_bool() {
    local name=$1 def=$2 v
    v=${!name:-$def}
    case "${v,,}" in
        1|true|yes|on) echo true ;;
        0|false|no|off) echo false ;;
        *) die "$name must be true or false (got '$v')" ;;
    esac
}

# env_int NAME DEFAULT MIN MAX -> prints the integer
env_int() {
    local name=$1 def=$2 min=$3 max=$4 v
    v=${!name:-$def}
    [[ "$v" =~ ^[0-9]{1,9}$ ]] || die "$name must be an integer (got '$v')"
    v=$((10#$v))
    (( v >= min && v <= max )) || die "$name must be between $min and $max (got $v)"
    echo "$v"
}

# env_enum NAME DEFAULT ALLOWED... -> prints the value (lower-cased)
env_enum() {
    local name=$1 def=$2 v a
    shift 2
    v=${!name:-$def}
    v=${v,,}
    for a in "$@"; do
        [ "$v" = "$a" ] && { echo "$v"; return 0; }
    done
    die "$name must be one of: $* (got '$v')"
}

valid_ifname() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,15}$ ]]; }

# ---------------------------------------------------------------------------
# IPv4 / IPv6 helpers
# ---------------------------------------------------------------------------

# ip4_to_int A.B.C.D -> integer (fails on malformed input; no leading zeros,
# which inet_pton rejects too)
ip4_to_int() {
    local re='^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$'
    [[ "$1" =~ $re ]] || return 1
    local o n=0
    for o in "${BASH_REMATCH[@]:1:4}"; do
        (( o <= 255 )) || return 1
        n=$(( (n << 8) | o ))
    done
    echo "$n"
}

int_to_ip4() {
    local n=$1
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# cidr4_range CIDR -> "START END" (host bits ignored); a bare address is a /32
cidr4_range() {
    local addr=${1%/*} len=32 ip mask start
    [[ "$1" == */* ]] && len=${1#*/}
    [[ "$len" =~ ^[0-9]{1,2}$ ]] && (( len <= 32 )) || return 1
    ip=$(ip4_to_int "$addr") || return 1
    if (( len == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF )); fi
    start=$(( ip & mask ))
    echo "$start $(( start | (~mask & 0xFFFFFFFF) ))"
}

# valid_subnet4 CIDR: network address with a /16../30 prefix (the range the
# mqvpn address pool accepts, see upstream src/addr_pool.c)
valid_subnet4() {
    [[ "$1" == */* ]] || return 1
    local len=${1#*/} r
    [[ "$len" =~ ^[0-9]{1,2}$ ]] && (( len >= 16 && len <= 30 )) || return 1
    r=$(cidr4_range "$1") || return 1
    [ "$(int_to_ip4 "${r% *}")" = "${1%/*}" ]
}

# valid_subnet6 CIDR6: IPv6 prefix /96../126 (upstream mqvpn_addr_pool_init6)
valid_subnet6() {
    local addr=${1%/*} len
    [[ "$1" =~ ^[0-9A-Fa-f:]+/([0-9]{1,3})$ ]] || return 1
    len=${BASH_REMATCH[1]}
    (( 10#$len >= 96 && 10#$len <= 126 )) || return 1
    [[ "$addr" == *::*::* ]] && return 1
    [[ "$addr" =~ ^[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7}$ ]]
}

valid_ip4() { ip4_to_int "$1" >/dev/null; }
valid_ip6() { [[ "$1" =~ ^[0-9A-Fa-f:.]+$ && "$1" == *:* ]]; }

# Interface / source address used to reach the internet (default route).
detect_uplink4() {
    ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1
}
detect_src4() {
    ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p' | head -n1
}
detect_uplink6() {
    ip -6 route get 2606:4700:4700::1111 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1
}
detect_src6() {
    ip -6 route get 2606:4700:4700::1111 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p' | head -n1
}

# ---------------------------------------------------------------------------
# sysctl (net.*) helpers
# ---------------------------------------------------------------------------

# sysctl_get KEY (KEY like net/ipv4/ip_forward)
sysctl_get() { cat "/proc/sys/$1" 2>/dev/null; }

host_sysctl_writable() {
    [ -w "$HOST_SYSCTL_NET/ipv4/ip_forward" ] 2>/dev/null
}

# sysctl_set KEY VALUE: write through the writable host mount and remember the
# original value so it can be restored on shutdown. Returns 1 if not writable.
sysctl_set() {
    local key=$1 val=$2 cur path
    cur=$(sysctl_get "$key") || return 1
    [ "$cur" = "$val" ] && return 0
    path="$HOST_SYSCTL_NET/${key#net/}"
    [ -w "$path" ] || return 1
    if ! grep -q "^${key}=" "$SYSCTL_RESTORE_FILE" 2>/dev/null; then
        printf '%s=%s=%s\n' "$key" "$cur" "$val" >> "$SYSCTL_RESTORE_FILE"
    fi
    printf '%s' "$val" > "$path" 2>/dev/null || return 1
    [ "$(sysctl_get "$key")" = "$val" ]
}

# Restore every sysctl this container changed, but only if nobody changed it
# again since (in that case someone else owns the value now).
sysctl_restore() {
    [ -f "$SYSCTL_RESTORE_FILE" ] || return 0
    local line key orig set cur
    while IFS= read -r line; do
        key=${line%%=*}; line=${line#*=}
        orig=${line%%=*}; set=${line#*=}
        cur=$(sysctl_get "$key") || continue
        if [ "$cur" = "$set" ] && [ -w "$HOST_SYSCTL_NET/${key#net/}" ]; then
            printf '%s' "$orig" > "$HOST_SYSCTL_NET/${key#net/}" 2>/dev/null \
                && info "restored $key=$orig"
        fi
    done < "$SYSCTL_RESTORE_FILE"
    rm -f "$SYSCTL_RESTORE_FILE"
}

# ---------------------------------------------------------------------------
# iptables backend
# ---------------------------------------------------------------------------

# The container must program the same backend (nf_tables or legacy x_tables)
# the host uses, otherwise the host's FORWARD DROP policy (set by Docker/UFW)
# in the other backend would still drop VPN traffic. Pick the backend that
# already holds rules (Docker always installs some).
detect_iptables_backend() {
    local want=${MQVPN_IPTABLES_BACKEND:-auto} n_nft n_legacy
    case "${want,,}" in
        nft|legacy) echo "${want,,}"; return 0 ;;
        auto) ;;
        *) die "MQVPN_IPTABLES_BACKEND must be auto, nft or legacy (got '$want')" ;;
    esac
    n_nft=$(iptables-nft-save 2>/dev/null | grep -c '^-A' || true)
    n_legacy=$(iptables-legacy-save 2>/dev/null | grep -c '^-A' || true)
    if (( ${n_legacy:-0} > ${n_nft:-0} )); then echo legacy; else echo nft; fi
}

ipt()  { "iptables-${IPT_BACKEND:?}" -w 10 "$@"; }
ip6t() { "ip6tables-${IPT_BACKEND:?}" -w 10 "$@"; }

# ---------------------------------------------------------------------------
# Runtime state shared between the entrypoint and the helper commands.
# Only non-secret values are stored here.
# ---------------------------------------------------------------------------

state_write() {
    local tmp
    tmp=$(mktemp "$RUN_DIR/.state.XXXXXX")
    {
        local v
        for v in "$@"; do
            printf '%s=%q\n' "$v" "${!v-}"
        done
    } > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

state_load() {
    # shellcheck disable=SC1090
    [ -r "$STATE_FILE" ] && . "$STATE_FILE"
}
