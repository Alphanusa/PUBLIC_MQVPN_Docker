#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# mqvpn-healthcheck — Docker HEALTHCHECK for the mqvpn server.
#
# Healthy only when all of these hold:
#   * the mqvpn process started by the entrypoint is running
#   * its TUN device exists and is UP
#   * a UDP socket is bound to the VPN port
#   * the control API answers a get_stats/get_status round trip (proves the
#     server's event loop, which also serves the VPN socket, is responsive)
#   * the NAT/forwarding rules are in place
# Prints one line; never prints secrets.

set -uo pipefail
LOG_TAG=healthcheck
# shellcheck source=common.sh
. /usr/local/lib/mqvpn-docker/common.sh

fail() { echo "unhealthy: $*"; exit 1; }

[ -f "$READY_FILE" ] || fail "server is still starting (or failed to start, see container logs)"
state_load || fail "no runtime state"

pid=$(cat "$PID_FILE" 2>/dev/null) || fail "no pid file"
[ "$(cat "/proc/$pid/comm" 2>/dev/null)" = mqvpn ] || fail "mqvpn process is not running"
st=$(sed -n 's/^.*) \([A-Za-z]\).*/\1/p' "/proc/$pid/stat" 2>/dev/null)
[ "$st" != Z ] || fail "mqvpn process has exited"

flags=$(cat "/sys/class/net/$TUN_NAME/flags" 2>/dev/null) || fail "TUN device $TUN_NAME is missing"
(( flags & 1 )) || fail "TUN device $TUN_NAME is down"

[ -n "$(ss -Hlun "sport = :$PORT" 2>/dev/null)" ] || fail "nothing listens on UDP port $PORT"

if [ "${CONTROL_OK:-0}" = 1 ]; then
    timeout 5 "$MQVPN_BIN" --status --control-addr 127.0.0.1 --control-port "$CONTROL_PORT" \
        >/dev/null 2>&1 || fail "control API on 127.0.0.1:$CONTROL_PORT does not answer (event loop stuck?)"
fi

/usr/local/bin/mqvpn-firewall check >/dev/null 2>&1 || fail "NAT/forwarding rules are missing (the watchdog re-applies them within 30 s)"

echo "healthy: UDP $PORT, $TUN_NAME up, NAT via ${UPLINK4:-?}"
exit 0
