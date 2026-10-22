#!/usr/bin/env bash
set -euo pipefail

: "${REGION:?}" "${HOST_ROLE:?}" "${NODE_COUNT:?}" "${HOST_SUBNET:?}"
: "${FLEET_IFACE:?}" "${KUBO_IMAGE:?}" "${SWARM_KEY_HOST:?}"
CONTAINER_NET="${CONTAINER_NET:-fleetnet}"
IP_OFFSET="${IP_OFFSET:-10}"
STATE_DIR="${STATE_DIR:-/var/run/kubo_fleet}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULTS_DIR="${STATE_DIR}/results/run-${RUN_ID}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$STATE_DIR" "$RESULTS_DIR"

# Subnet prefix (first three octets), e.g. 10.20.8 from 10.20.8.0/24.
prefix="$(echo "$HOST_SUBNET" | cut -d/ -f1 | cut -d. -f1-3)"

BRIDGE_IF="${BRIDGE_IF:-fleetbr0}"
gateway="${prefix}.1"

# Self-heal: an older run may have left an ipvlan network with this name.
if docker network inspect "$CONTAINER_NET" >/dev/null 2>&1; then
    drv="$(docker network inspect -f '{{.Driver}}' "$CONTAINER_NET")"
    if [ "$drv" != "bridge" ]; then
        docker ps -aq --filter "network=$CONTAINER_NET" | xargs -r docker rm -f >/dev/null
        docker network rm "$CONTAINER_NET" >/dev/null
        echo "removed stale $drv network $CONTAINER_NET"
    fi
fi

if ! docker network inspect "$CONTAINER_NET" >/dev/null 2>&1; then
    net_opts=(
        -o com.docker.network.bridge.name="$BRIDGE_IF"
        -o com.docker.network.bridge.enable_ip_masquerade=false
        -o com.docker.network.driver.mtu=1400
    )
    # Docker >= 28 blocks direct (unpublished) access to container IPs unless the
    # network is in "routed" gateway mode; older versions don't know the option.
    dmaj="$(docker version -f '{{.Server.Version}}' | cut -d. -f1)"
    if [ "${dmaj:-0}" -ge 28 ]; then
        net_opts+=( -o com.docker.network.bridge.gateway_mode_ipv4=routed )
    fi
    docker network create -d bridge \
        --subnet="$HOST_SUBNET" --gateway="$gateway" \
        "${net_opts[@]}" \
        "$CONTAINER_NET" >/dev/null
    echo "created routed bridge $CONTAINER_NET ($BRIDGE_IF, $HOST_SUBNET, no NAT, mtu=1400)"
fi

# Docker's FORWARD policy is DROP for traffic it didn't create; explicitly allow
# the mesh <-> bridge path (DOCKER-USER is evaluated first). Idempotent via -C.
for rule in "-i $FLEET_IFACE -o $BRIDGE_IF" "-i $BRIDGE_IF -o $FLEET_IFACE"; do
    # shellcheck disable=SC2086
    iptables -C DOCKER-USER $rule -j ACCEPT 2>/dev/null \
        || iptables -I DOCKER-USER $rule -j ACCEPT
done
echo "forwarding allowed: $FLEET_IFACE <-> $BRIDGE_IF"

launch_one() {
    local idx="$1" role="$2" ip="$3" boot="${4:-}"
    local name
    name="node-${REGION}-$(printf '%04d' "$idx")"
    NODE_NAME="$name" NODE_ROLE="$role" CONTAINER_NET="$CONTAINER_NET" NODE_IP="$ip" \
    KUBO_IMAGE="$KUBO_IMAGE" SWARM_KEY_HOST="$SWARM_KEY_HOST" RESULTS_DIR="$RESULTS_DIR" \
    BOOTSTRAP_MADDR="$boot" \
    EXP_DHT_ALPHA="${EXP_DHT_ALPHA:-}" EXP_DHT_BUCKET_K="${EXP_DHT_BUCKET_K:-}" \
    EXP_DHT_PRIVATE_NET="${EXP_DHT_PRIVATE_NET:-1}" \
    NETEM_DELAY="${NETEM_DELAY:-}" NETEM_JITTER="${NETEM_JITTER:-}" NETEM_LOSS="${NETEM_LOSS:-}" \
    CPU_LIMIT="${CPU_LIMIT:-}" MEM_LIMIT="${MEM_LIMIT:-}" \
        bash "${here}/launch_node.sh"
    echo "$name $ip $role" >>"${STATE_DIR}/nodes.list"
}

: >"${STATE_DIR}/nodes.list"
start=1
boot_maddr="${BOOTSTRAP_MADDR:-}"

# --- optional: this host runs the bootstrap node (first index) ----------------
if [ "${RUN_BOOTSTRAP:-0}" = "1" ]; then
    boot_ip="${prefix}.${IP_OFFSET}"
    launch_one 1 bootstrap "$boot_ip" ""
    echo "waiting for bootstrap node to report its peer id..."
    peerid=""
    for _ in $(seq 1 90); do
        # Ask the RUNNING daemon over its API. A bare `ipfs id` opens the repo
        # offline: it returns a peer id even if the daemon is dead (false
        # "bootstrap ready") AND grabs repo.lock, racing the entrypoint's
        # `ipfs config` calls.
        peerid="$(docker exec "node-${REGION}-0001" ipfs --api=/ip4/127.0.0.1/tcp/5001 id -f '<id>' 2>/dev/null || true)"
        [ -n "$peerid" ] && break
        sleep 2
    done
    if [ -z "$peerid" ]; then
        echo "fleet_host_up: bootstrap node never reported a peer id" >&2
        exit 1
    fi
    boot_maddr="/ip4/${boot_ip}/tcp/4001/p2p/${peerid}"
    echo "$boot_maddr" >"${STATE_DIR}/bootstrap.maddr"
    echo "bootstrap ready: $boot_maddr"
    start=2
fi

# --- launch the remaining nodes -----------------------------------------------
for i in $(seq "$start" "$NODE_COUNT"); do
    ip="${prefix}.$((IP_OFFSET + i - 1))"
    launch_one "$i" "$HOST_ROLE" "$ip" "$boot_maddr"
done

echo "host up: ${NODE_COUNT} node(s) in region=${REGION} role=${HOST_ROLE} subnet=${HOST_SUBNET}"
