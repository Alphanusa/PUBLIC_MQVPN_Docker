#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# mqvpn-firewall — NAT/forwarding rules for the mqvpn server container.
#
# Usage: mqvpn-firewall setup|teardown|check|status
#
# The container shares the host network namespace, so these rules live in the
# host's firewall. To stay out of the way of Docker, Dokploy, UFW and SSH:
#   * every rule lives in a dedicated chain named after the TUN device
#     (MQVPN-FWD-<tun>, MQVPN-NAT-<tun>, optionally MQVPN-IN-<tun>);
#   * the only change to built-in chains is ONE jump rule per chain;
#   * policies and other chains are never touched or flushed;
#   * setup is idempotent (chains are flushed and refilled, the jump is
#     de-duplicated), teardown removes exactly what setup added.
#
# Configuration comes from the state file written by the entrypoint
# (/run/mqvpn/state.env). Without one (e.g. a manual cleanup with
# `docker compose run --rm mqvpn mqvpn-firewall teardown`), teardown falls back
# to MQVPN_TUN_NAME / MQVPN_IPTABLES_BACKEND from the environment.

set -Eeuo pipefail
LOG_TAG=firewall
# shellcheck source=common.sh
. /usr/local/lib/mqvpn-docker/common.sh

# Destinations VPN clients must not reach through the server by default:
# RFC 1918, CGNAT (100.64/10, e.g. Tailscale), link-local (cloud metadata
# 169.254.169.254), multicast and reserved space. Mirrors the default-deny
# list upstream applies to its hybrid TCP lane (src/hybrid/tcp_egress.c).
PRIVATE4=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 224.0.0.0/4 240.0.0.0/4)
PRIVATE6=(fc00::/7 fe80::/10 ff00::/8)

load_config() {
    state_load || true
    TUN_NAME=${TUN_NAME:-${MQVPN_TUN_NAME:-mqvpn0}}
    valid_ifname "$TUN_NAME" || die "invalid TUN name '$TUN_NAME'"
    IPT_BACKEND=${IPT_BACKEND:-$(detect_iptables_backend)}
    CH_FWD="MQVPN-FWD-$TUN_NAME"
    CH_NAT="MQVPN-NAT-$TUN_NAME"
    CH_IN="MQVPN-IN-$TUN_NAME"
}

ipv6_usable() {
    [ -d /proc/sys/net/ipv6 ] && ip6t -t filter -n -L FORWARD >/dev/null 2>&1
}

# _chain_reset CMD TABLE CHAIN: create (if needed) and flush a chain
_chain_reset() {
    local cmd=$1 table=$2 chain=$3
    "$cmd" -t "$table" -N "$chain" 2>/dev/null || true
    "$cmd" -t "$table" -F "$chain"
}

# _jump_ensure CMD TABLE BUILTIN CHAIN: exactly one jump, at position 1
_jump_ensure() {
    local cmd=$1 table=$2 builtin=$3 chain=$4
    while "$cmd" -t "$table" -D "$builtin" -j "$chain" 2>/dev/null; do :; done
    "$cmd" -t "$table" -I "$builtin" 1 -j "$chain"
}

# _chain_remove CMD TABLE BUILTIN CHAIN
_chain_remove() {
    local cmd=$1 table=$2 builtin=$3 chain=$4
    while "$cmd" -t "$table" -D "$builtin" -j "$chain" 2>/dev/null; do :; done
    "$cmd" -t "$table" -F "$chain" 2>/dev/null || true
    "$cmd" -t "$table" -X "$chain" 2>/dev/null || true
}

# _fw_family CMD SUBNET UPLINK PRIVATE...: program one address family
_fw_family() {
    local cmd=$1 subnet=$2 uplink=$3 net
    shift 3

    # filter/FORWARD: only traffic entering or leaving the TUN is matched.
    _chain_reset "$cmd" filter "$CH_FWD"
    # replies to client traffic (and ICMP errors about it)
    "$cmd" -t filter -A "$CH_FWD" -o "$TUN_NAME" -d "$subnet" \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    # client <-> client inside the tunnel subnet
    "$cmd" -t filter -A "$CH_FWD" -i "$TUN_NAME" -o "$TUN_NAME" -s "$subnet" -d "$subnet" -j ACCEPT
    if [ "${BLOCK_PRIVATE:-true}" = true ]; then
        for net in "$@"; do
            "$cmd" -t filter -A "$CH_FWD" -i "$TUN_NAME" -d "$net" -j DROP
        done
    fi
    # client traffic to the internet
    "$cmd" -t filter -A "$CH_FWD" -i "$TUN_NAME" -s "$subnet" -j ACCEPT
    # anything else from the TUN (spoofed source) and unsolicited traffic to clients
    "$cmd" -t filter -A "$CH_FWD" -i "$TUN_NAME" -j DROP
    "$cmd" -t filter -A "$CH_FWD" -o "$TUN_NAME" -j DROP
    _jump_ensure "$cmd" filter FORWARD "$CH_FWD"

    # nat/POSTROUTING: masquerade client traffic leaving to the internet
    _chain_reset "$cmd" nat "$CH_NAT"
    if [ "$uplink" = any ]; then
        "$cmd" -t nat -A "$CH_NAT" -s "$subnet" ! -o "$TUN_NAME" -j MASQUERADE
    else
        "$cmd" -t nat -A "$CH_NAT" -s "$subnet" -o "$uplink" -j MASQUERADE
    fi
    _jump_ensure "$cmd" nat POSTROUTING "$CH_NAT"

    # filter/INPUT (opt-in): accept the VPN port even if the host firewall
    # (e.g. UFW) drops it by default
    if [ "${OPEN_INPUT_PORT:-false}" = true ]; then
        _chain_reset "$cmd" filter "$CH_IN"
        "$cmd" -t filter -A "$CH_IN" -p udp --dport "$PORT" -j ACCEPT
        _jump_ensure "$cmd" filter INPUT "$CH_IN"
    else
        _chain_remove "$cmd" filter INPUT "$CH_IN"
    fi
}

fw_setup() {
    : "${SUBNET:?}" "${PORT:?}" "${UPLINK4:?}"
    _fw_family ipt "$SUBNET" "$UPLINK4" "${PRIVATE4[@]}"
    if [ -n "${SUBNET6:-}" ]; then
        : "${UPLINK6:?}"
        _fw_family ip6t "$SUBNET6" "$UPLINK6" "${PRIVATE6[@]}"
    elif ipv6_usable; then
        _chain_remove ip6t filter FORWARD "$CH_FWD"
        _chain_remove ip6t nat POSTROUTING "$CH_NAT"
        _chain_remove ip6t filter INPUT "$CH_IN"
    fi
    info "rules installed (iptables-$IPT_BACKEND): $SUBNET -> ${UPLINK4}${SUBNET6:+, $SUBNET6 -> $UPLINK6}, private destinations $([ "${BLOCK_PRIVATE:-true}" = true ] && echo blocked || echo allowed)"
}

fw_teardown() {
    _chain_remove ipt filter FORWARD "$CH_FWD"
    _chain_remove ipt nat POSTROUTING "$CH_NAT"
    _chain_remove ipt filter INPUT "$CH_IN"
    if ipv6_usable; then
        _chain_remove ip6t filter FORWARD "$CH_FWD"
        _chain_remove ip6t nat POSTROUTING "$CH_NAT"
        _chain_remove ip6t filter INPUT "$CH_IN"
    fi
    info "rules removed (iptables-$IPT_BACKEND, $TUN_NAME)"
}

# Exit 0 when every jump and every chain is in place (cheap, used by the
# watchdog and the healthcheck).
fw_check() {
    ipt -t filter -C FORWARD -j "$CH_FWD" 2>/dev/null || return 1
    ipt -t nat -C POSTROUTING -j "$CH_NAT" 2>/dev/null || return 1
    [ "$(ipt -t nat -S "$CH_NAT" 2>/dev/null | grep -c '^-A')" -ge 1 ] || return 1
    [ "$(ipt -t filter -S "$CH_FWD" 2>/dev/null | grep -c '^-A')" -ge 3 ] || return 1
    if [ "${OPEN_INPUT_PORT:-false}" = true ]; then
        ipt -t filter -C INPUT -j "$CH_IN" 2>/dev/null || return 1
    fi
    if [ -n "${SUBNET6:-}" ]; then
        ip6t -t filter -C FORWARD -j "$CH_FWD" 2>/dev/null || return 1
        ip6t -t nat -C POSTROUTING -j "$CH_NAT" 2>/dev/null || return 1
    fi
    return 0
}

fw_status() {
    echo "# backend: iptables-$IPT_BACKEND, tun: $TUN_NAME"
    ipt -t filter -S "$CH_FWD" 2>/dev/null || echo "# $CH_FWD: not present"
    ipt -t nat -S "$CH_NAT" 2>/dev/null || echo "# $CH_NAT: not present"
    ipt -t filter -S "$CH_IN" 2>/dev/null || true
    if ipv6_usable; then
        ip6t -t filter -S "$CH_FWD" 2>/dev/null || true
        ip6t -t nat -S "$CH_NAT" 2>/dev/null || true
    fi
}

main() {
    local action=${1:-}
    case "$action" in
        setup|teardown|check|status) ;;
        *) echo "Usage: $0 setup|teardown|check|status" >&2; exit 2 ;;
    esac
    [ "$(id -u)" -eq 0 ] || die "must run as root"
    load_config
    case "$action" in
        setup)    fw_setup ;;
        teardown) fw_teardown ;;
        check)    fw_check ;;
        status)   fw_status ;;
    esac
}

main "$@"
