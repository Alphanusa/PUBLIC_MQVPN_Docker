#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# mqvpn-paths — show every connected client and its multipath paths, using
# the server's local control API (get_status).
#
# Usage: mqvpn-paths [--watch SECONDS] [--json]
#
# With --watch, each path's current throughput is shown. A phone that bonds
# Wi-Fi and mobile data shows two (or more) paths in state "active", each
# carrying traffic. "down" = server -> phone, "up" = phone -> server.

set -uo pipefail
LOG_TAG=paths
# shellcheck source=common.sh
. /usr/local/lib/mqvpn-docker/common.sh

usage() { echo "Usage: mqvpn-paths [--watch SECONDS] [--json]"; }

WATCH=0
JSON=0
while [ $# -gt 0 ]; do
    case "$1" in
        --watch|-w)
            [[ "${2:-}" =~ ^[0-9]+$ ]] && (( $2 >= 1 )) || { usage >&2; exit 2; }
            WATCH=$2; shift 2 ;;
        --json) JSON=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

state_load || { echo "the server has not started yet; check the container logs" >&2; exit 1; }
if [ "${CONTROL_PORT:-0}" = 0 ] || [ "${CONTROL_OK:-0}" != 1 ]; then
    echo "the control API is disabled or not answering (MQVPN_CONTROL_PORT); per-path statistics are unavailable" >&2
    exit 1
fi

# One newline-delimited JSON request per connection (upstream protocol).
query() {
    local line=
    exec 3<>"/dev/tcp/127.0.0.1/$CONTROL_PORT" || return 1
    printf '%s\n' "$1" >&3
    IFS= read -r -t 5 -u 3 line || [ -n "$line" ] || { exec 3>&-; return 1; }
    exec 3>&-
    printf '%s' "$line"
}

# shellcheck disable=SC2016  # jq program, not shell
JQ_PROG='
def human: if . >= 1073741824 then "\((. / 1073741824 * 10 | floor) / 10) GiB"
           elif . >= 1048576 then "\((. / 1048576 * 10 | floor) / 10) MiB"
           elif . >= 1024 then "\((. / 1024 * 10 | floor) / 10) KiB"
           else "\(.) B" end;
def dur: if . >= 3600 then "\(. / 3600 | floor)h \((. % 3600) / 60 | floor)m"
         elif . >= 60 then "\(. / 60 | floor)m \(. % 60)s" else "\(.)s" end;
def pad($n): tostring | if length < $n then . + (" " * ($n - length)) else . end;
def mbps($d): if $dt > 0 and $d >= 0 then "\(($d * 8 / $dt / 1000000 * 100 | round) / 100) Mbit/s" else "-" end;
($prev // {clients: []}) as $p
| ([$p.clients[]? | . as $c | $c.paths[]? | {key: "\($c.user)|\($c.endpoint)|\(.path_id)", value: .}] | from_entries) as $old
| "mqvpn server \($ver) - \(.n_clients // 0) client(s) connected",
  (if (.n_clients // 0) == 0 then "  (no connected clients)" else empty end),
  (.clients[]? as $c
   | "",
     "client \($c.user)  endpoint \($c.endpoint)  connected \($c.connected_sec | dur)  scheduler \($c.scheduler)",
     "  total: \($c.bytes_tx | human) down, \($c.bytes_rx | human) up, \($c.paths | length) path(s), \([$c.paths[] | select(.state_label | test("active"))] | length) active",
     "  \("path" | pad(5))\("state" | pad(22))\("srtt" | pad(8))\("down total" | pad(12))\("up total" | pad(12))\(if $dt > 0 then ("down now" | pad(16)) + ("up now" | pad(16)) else "" end)lost",
     ($c.paths[] as $q
      | ($old["\($c.user)|\($c.endpoint)|\($q.path_id)"]) as $o
      | "  \($q.path_id | pad(5))\($q.state_label | pad(22))\("\($q.srtt_ms)ms" | pad(8))\($q.bytes_tx | human | pad(12))\($q.bytes_rx | human | pad(12))\(if $dt > 0 then (if $o then (mbps($q.bytes_tx - $o.bytes_tx) | pad(16)) + (mbps($q.bytes_rx - $o.bytes_rx) | pad(16)) else ("new" | pad(16)) + ("" | pad(16)) end) else "" end)\($q.pkt_lost)"))
'

render() { # render CURRENT PREV DT
    jq -r --argjson prev "${2:-null}" --argjson dt "${3:-0}" --arg ver "$VERSION" "$JQ_PROG" <<< "$1"
}

VERSION=$("$MQVPN_BIN" --version 2>/dev/null | awk '{print $2}')
cur=$(query '{"cmd":"get_status"}') || { echo "control API query failed" >&2; exit 1; }
if [ "$JSON" = 1 ]; then
    printf '%s\n' "$cur"
    exit 0
fi
render "$cur" null 0 || { echo "unexpected control API reply" >&2; exit 1; }
[ "$WATCH" = 0 ] && exit 0

while :; do
    sleep "$WATCH"
    prev=$cur
    cur=$(query '{"cmd":"get_status"}') || { echo "control API query failed" >&2; exit 1; }
    echo
    echo "---- $(date -u '+%H:%M:%S') (rates over the last ${WATCH}s) ----"
    render "$cur" "$prev" "$WATCH"
done
