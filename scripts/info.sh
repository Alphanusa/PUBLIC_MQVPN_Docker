#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# mqvpn-info — connection details for the Android/desktop clients.
#
# Usage: mqvpn-info [--show-key]
#
# Keys are masked unless --show-key is given. They are never written to the
# container log; this command prints them only to the terminal that runs it.

set -uo pipefail
LOG_TAG=info
# shellcheck source=common.sh
. /usr/local/lib/mqvpn-docker/common.sh

SHOW_KEY=0
case "${1:-}" in
    --show-key) SHOW_KEY=1 ;;
    "") ;;
    -h|--help) echo "Usage: mqvpn-info [--show-key]"; exit 0 ;;
    *) echo "Usage: mqvpn-info [--show-key]" >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "run as root (docker exec runs as root by default)" >&2; exit 1; }
state_load || { echo "the server has not started yet (no $STATE_FILE); check the container logs" >&2; exit 1; }

mask() { printf '<hidden: %s characters, use --show-key>' "${#1}"; }
show() { if [ "$SHOW_KEY" = 1 ]; then printf '%s' "$1"; else mask "$1"; fi; }

# The global key is read from the rendered config: it may come from the
# volume (auth.key) or from MQVPN_AUTH_KEY.
global_key=$(sed -n '/^\[Auth\]/,/^\[/ s/^Key = //p' "$CONF_FILE" | head -n1)

addr=${PUBLIC_HOST:-<server-public-ip>}
[[ "$addr" == *:* ]] && addr="[$addr]"
status=stopped
[ -f "$READY_FILE" ] && status=running

cat <<EOF

  mqvpn server: $status ($("$MQVPN_BIN" --version 2>/dev/null))

  Android app (mqvpn, org.mqvpn.app) -> "Connect to your server":
    Server address : $addr:$PORT
EOF
if [ "${PUBLIC_HOST_AUTO:-0}" = 1 ]; then
    echo "                     (auto-detected; behind 1:1 NAT use the public IP, or set MQVPN_PUBLIC_HOST)"
fi
if [ -n "$global_key" ]; then
    echo "    Access key     : $(show "$global_key")"
fi
if [ -n "${USERS_LIST:-}" ]; then
    for u in $USERS_LIST; do
        k=$(head -n1 "$DATA_DIR/users/$u.key" 2>/dev/null) || continue
        echo "    Access key ($u): $(show "$k")"
    done
fi
if [ "$TLS_MODE" = self-signed ]; then
    cat <<EOF
    Trust self-signed certificate : ON (this server uses a self-signed certificate)
EOF
else
    cat <<EOF
    Trust self-signed certificate : OFF (certificate: $TLS_SUBJECT)
    TLS server name               : only needed if "Server address" is an IP: use the name in the certificate
EOF
fi
cat <<EOF

  Linux CLI client:
    sudo mqvpn --mode client --server $addr:$PORT --auth-key <ACCESS_KEY> \\
        --path wlan0 --path wwan0$( [ "$TLS_MODE" = self-signed ] && echo " --insecure" )

  Server:
    UDP port        : $PORT (must be open in the VPS / cloud firewall)
    IPv4 subnet     : $SUBNET (NAT via ${UPLINK4:-?}, iptables-${IPT_BACKEND:-?})
    IPv6            : ${IPV6_STATUS:-?}
    Scheduler / CC  : ${SCHEDULER:-?} / ${CC:-?} (hybrid TCP lane: ${HYBRID:-?}, reorder: ${REORDER:-?})
    Max clients     : ${MAX_CLIENTS:-?}
    TLS certificate : ${TLS_MODE:-?}, SHA-256 ${TLS_FINGERPRINT:-?}
                      valid until ${TLS_NOT_AFTER:-?}
    Control API     : $( [ "${CONTROL_PORT:-0}" != 0 ] && echo "127.0.0.1:$CONTROL_PORT (host loopback only)" || echo disabled )

  Check that Wi-Fi and mobile data are both used: mqvpn-paths --watch 5

EOF
