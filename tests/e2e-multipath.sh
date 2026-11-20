#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# End-to-end test of the mqvpn server container on a Linux Docker host.
#
# Builds and starts the compose stack (as project "mqvpn-e2e", on test-only
# port/subnet/TUN so it does not clash with a real deployment) and a Linux
# mqvpn client in a second container that has TWO network interfaces, each on
# its own Docker bridge limited to PATH_RATE (tbf). This emulates a phone with
# Wi-Fi + mobile data. Then it checks:
#   1. the client gets a tunnel and reaches an "internet" host through the
#      server's NAT
#   2. both paths are active and carry traffic (server control API)
#   3. bonded throughput exceeds what a single path can carry, for parallel
#      flows (WLB scheduler) and for ONE TCP flow (hybrid TCP lane)
#   4. failover: traffic continues when one path goes down
#   5. private destinations are blocked (MQVPN_BLOCK_PRIVATE_NETWORKS)
#   6. credentials survive container re-creation, and are not in the logs
#   7. firewall rules are removed when the stack stops
#
# Usage (as root, from the repository root):  tests/e2e-multipath.sh
# Environment: BUSYBOX_IMAGE (default mirror.gcr.io/library/busybox:1.37),
#              PATH_RATE (default 20mbit), KEEP=1 to leave everything running,
#              BUILD_ARGS (extra args for `docker compose build`).

# shellcheck disable=SC2015,SC2016  # pass/fail always succeed; remote sh -c bodies
set -Eeuo pipefail
cd "$(dirname "$0")/.."

BUSYBOX_IMAGE=${BUSYBOX_IMAGE:-mirror.gcr.io/library/busybox:1.37}
PATH_RATE=${PATH_RATE:-20mbit}
PROJECT=mqvpn-e2e
PORT=14443
CTRL=19091
TUN=mqvpne2e0
SUBNET=10.71.0.0/24
NET_A=mqvpn-e2e-a     # "Wi-Fi"
NET_B=mqvpn-e2e-b     # "mobile data"
NET_INET=mqvpn-e2e-inet
NET_PRIV=mqvpn-e2e-priv
CLIENT=mqvpn-e2e-client
TARGET=mqvpn-e2e-target
PRIVTARGET=mqvpn-e2e-priv-target
SERVER_A=172.30.101.1
TARGET_IP=198.51.100.10   # TEST-NET-2: treated as a public address
PRIV_IP=172.30.104.10

export MQVPN_PORT=$PORT MQVPN_CONTROL_PORT=$CTRL MQVPN_TUN_NAME=$TUN MQVPN_SUBNET=$SUBNET
# The test "internet" is a Docker bridge, not the default route: NAT to any
# interface except the tunnel.
export MQVPN_NAT_INTERFACE=any MQVPN_SUBNET6=off MQVPN_LOG_LEVEL=info
COMPOSE=(docker compose -p "$PROJECT")

pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
step() { printf '\n== %s\n' "$*"; }
FAILED=0

teardown_env() {
    docker rm -f "$CLIENT" "$TARGET" "$PRIVTARGET" >/dev/null 2>&1 || true
    "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
    for n in "$NET_A" "$NET_B" "$NET_INET" "$NET_PRIV"; do docker network rm "$n" >/dev/null 2>&1 || true; done
}
cleanup() {
    local rc=$?
    if [ "${KEEP:-0}" = 1 ]; then
        echo "KEEP=1: leaving the test environment running (clean up: KEEP=0 $0, or docker compose -p $PROJECT down -v)"
    else
        teardown_env
    fi
    return "$rc"
}
trap cleanup EXIT

bb() { docker run --rm --network "container:$CLIENT" "$BUSYBOX_IMAGE" "$@"; }
hosttc() { docker run --rm --network host --cap-add NET_ADMIN --entrypoint tc "$IMAGE" "$@"; }

# Download COUNT copies of /big in parallel through the tunnel; prints Mbit/s.
throughput() {
    local count=$1 start end bytes
    start=$(date +%s.%N)
    bb sh -c "for i in \$(seq 1 $count); do wget -q -O /dev/null http://$TARGET_IP/big & done; wait"
    end=$(date +%s.%N)
    bytes=$((count * 32 * 1024 * 1024))
    awk -v b="$bytes" -v s="$start" -v e="$end" 'BEGIN { printf "%.1f", b * 8 / (e - s) / 1e6 }'
}

start_client() { # start_client [--hybrid] PATH...
    local hybrid=false p
    [ "${1:-}" = --hybrid ] && { hybrid=true; shift; }
    {
        echo "[Server]"
        echo "Address = $SERVER_A:$PORT"
        echo "Insecure = true"
        echo "[Auth]"
        echo "Key = $KEY"
        echo "[Multipath]"
        for p in "$@"; do echo "Path = $p"; done
        echo "[Hybrid]"
        echo "Enabled = $hybrid"
    } | docker exec -i "$CLIENT" sh -c 'umask 077; cat > /tmp/client.conf'
    docker exec "$CLIENT" sh -c 'pkill -x mqvpn; sleep 1' >/dev/null 2>&1 || true
    docker exec -d "$CLIENT" sh -c "mqvpn --config /tmp/client.conf > /tmp/client.log 2>&1"
    for _ in $(seq 1 30); do
        docker exec "$CLIENT" sh -c "ip -4 addr show dev mqvpn0 2>/dev/null | grep -q 'inet '" && return 0
        sleep 1
    done
    docker exec "$CLIENT" cat /tmp/client.log || true
    return 1
}

step "build and start the server stack"
teardown_env
# shellcheck disable=SC2086
"${COMPOSE[@]}" build ${BUILD_ARGS:-} >/dev/null
"${COMPOSE[@]}" up -d --no-build
IMAGE=$("${COMPOSE[@]}" images -q mqvpn | head -n1)
for _ in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$("${COMPOSE[@]}" ps -q mqvpn)")" = healthy ] && break
    sleep 2
done
if [ "$(docker inspect -f '{{.State.Health.Status}}' "$("${COMPOSE[@]}" ps -q mqvpn)")" = healthy ]; then
    pass "server container is healthy"
else
    fail "server container is not healthy"; "${COMPOSE[@]}" logs; exit 1
fi
KEY=$("${COMPOSE[@]}" exec -T mqvpn sh -c 'cat /etc/mqvpn/auth.key')
CERT_FP=$("${COMPOSE[@]}" exec -T mqvpn sh -c '. /run/mqvpn/state.env; echo "$TLS_FINGERPRINT"')
if "${COMPOSE[@]}" logs 2>&1 | grep -qF "$KEY"; then fail "auth key appears in the logs"; else pass "auth key is not in the logs"; fi

step "test networks: two client paths limited to $PATH_RATE each, one 'internet' and one private network"
docker network create -o com.docker.network.bridge.name=mqe2e-a --subnet 172.30.101.0/24 --gateway "$SERVER_A" "$NET_A" >/dev/null
docker network create -o com.docker.network.bridge.name=mqe2e-b --subnet 172.30.102.0/24 "$NET_B" >/dev/null
# nat-unprotected: Docker itself does not filter direct access to these
# containers, so only the mqvpn rules decide (like a real internet host, and
# so the private-network block is really tested).
docker network create -o com.docker.network.bridge.name=mqe2e-inet \
    -o com.docker.network.bridge.gateway_mode_ipv4=nat-unprotected --subnet 198.51.100.0/24 "$NET_INET" >/dev/null
docker network create -o com.docker.network.bridge.name=mqe2e-priv \
    -o com.docker.network.bridge.gateway_mode_ipv4=nat-unprotected --subnet 172.30.104.0/24 "$NET_PRIV" >/dev/null
docker run -d --name "$TARGET" --network "$NET_INET" --ip "$TARGET_IP" "$BUSYBOX_IMAGE" \
    sh -c 'mkdir -p /www && dd if=/dev/zero of=/www/big bs=1M count=32 2>/dev/null && echo ok > /www/ok && httpd -f -p 80 -h /www' >/dev/null
docker run -d --name "$PRIVTARGET" --network "$NET_PRIV" --ip "$PRIV_IP" "$BUSYBOX_IMAGE" \
    sh -c 'mkdir -p /www && echo secret > /www/ok && httpd -f -p 80 -h /www' >/dev/null
docker run -d --name "$CLIENT" --network "$NET_A" --cap-add NET_ADMIN --device /dev/net/tun \
    "$IMAGE" sleep infinity >/dev/null
docker network connect "$NET_B" "$CLIENT"
# download direction: shape the host bridges; upload: shape the client NICs
for br in mqe2e-a mqe2e-b; do hosttc qdisc add dev "$br" root tbf rate "$PATH_RATE" burst 64kb latency 100ms; done
for dev in eth0 eth1; do docker exec "$CLIENT" tc qdisc add dev "$dev" root tbf rate "$PATH_RATE" burst 64kb latency 100ms; done

step "single path baseline (eth0 only)"
start_client eth0 && pass "client connected over one path" || { fail "client did not connect"; exit 1; }
if bb wget -q -T 5 -O - "http://$TARGET_IP/ok" | grep -q ok; then pass "internet host reachable through the tunnel (NAT)"; else fail "internet host not reachable"; fi
SINGLE=$(throughput 6)
SINGLE1=$(throughput 1)
echo "single path, 1 flow: $SINGLE1 Mbit/s"
echo "single path: $SINGLE Mbit/s"

step "multipath (eth0 = Wi-Fi, eth1 = mobile data)"
start_client eth0 eth1 && pass "client connected over two paths" || { fail "client did not connect"; exit 1; }
sleep 3
MULTI=$(throughput 6)
echo "multipath:   $MULTI Mbit/s"
"${COMPOSE[@]}" exec -T mqvpn mqvpn-paths
ACTIVE=$("${COMPOSE[@]}" exec -T mqvpn sh -c 'mqvpn-paths --json | jq "[.clients[0].paths[] | select(.state_label | test(\"active\")) | select(.bytes_tx > 1000000)] | length"')
if [ "${ACTIVE:-0}" -ge 2 ]; then pass "$ACTIVE paths active and each carried > 1 MB"; else fail "only ${ACTIVE:-0} path(s) carried traffic"; fi
if awk -v m="$MULTI" -v s="$SINGLE" 'BEGIN { exit !(m > s * 1.25) }'; then
    pass "bonded throughput $MULTI Mbit/s > 1.25 x single path $SINGLE Mbit/s (6 parallel flows)"
else
    fail "no aggregation: multipath $MULTI Mbit/s vs single path $SINGLE Mbit/s"
fi

step "multipath + hybrid TCP lane, ONE TCP flow"
start_client --hybrid eth0 eth1 && pass "client connected with the hybrid TCP lane" || fail "hybrid client did not connect"
sleep 3
HYB=$(throughput 1)
echo "hybrid, 1 flow: $HYB Mbit/s (single path, 1 flow: $SINGLE1 Mbit/s)"
if awk -v m="$HYB" -v s="$SINGLE1" 'BEGIN { exit !(m > s * 1.25) }'; then
    pass "one TCP flow aggregates both paths via the server's hybrid lane"
else
    fail "hybrid lane did not aggregate a single flow ($HYB vs $SINGLE1 Mbit/s)"
fi
start_client eth0 eth1 >/dev/null

step "failover: take eth1 down during a download"
( sleep 2; docker exec "$CLIENT" ip link set eth1 down ) &
if bb sh -c "wget -q -T 20 -O /dev/null http://$TARGET_IP/big"; then pass "download completed while a path went down"; else fail "download broke on path loss"; fi
wait
docker exec "$CLIENT" ip link set eth1 up

step "private destinations are blocked"
if bb wget -q -T 4 -O - "http://$PRIV_IP/ok" >/dev/null 2>&1; then
    fail "client reached a private network ($PRIV_IP) through the server"
else
    pass "private network $PRIV_IP is not reachable through the tunnel"
fi

step "credentials persist across container re-creation"
"${COMPOSE[@]}" up -d --no-build --force-recreate >/dev/null 2>&1
sleep 5
KEY2=$("${COMPOSE[@]}" exec -T mqvpn sh -c 'cat /etc/mqvpn/auth.key')
CERT_FP2=$("${COMPOSE[@]}" exec -T mqvpn sh -c '. /run/mqvpn/state.env; echo "$TLS_FINGERPRINT"')
[ "$KEY" = "$KEY2" ] && pass "auth key unchanged" || fail "auth key changed"
[ "$CERT_FP" = "$CERT_FP2" ] && pass "certificate unchanged" || fail "certificate changed"
start_client eth0 eth1 && pass "client reconnects after re-creation" || fail "client cannot reconnect"

step "firewall cleanup on stop"
"${COMPOSE[@]}" stop >/dev/null 2>&1
if docker run --rm --network host --cap-add NET_ADMIN --cap-add NET_RAW --entrypoint sh "$IMAGE" \
    -c "iptables-nft-save; ip6tables-nft-save; iptables-legacy-save" 2>/dev/null | grep -q "MQVPN-.*-$TUN"; then
    fail "firewall rules left behind"
else
    pass "all MQVPN-*-$TUN chains removed"
fi

echo
if [ "$FAILED" = 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; exit 1; fi
