#!/usr/bin/env bash
set -euo pipefail

: "${NODE_NAME:?}" "${NODE_ROLE:?}" "${CONTAINER_NET:?}" "${NODE_IP:?}"
: "${KUBO_IMAGE:?}" "${SWARM_KEY_HOST:?}" "${RESULTS_DIR:?}"
EXP_DHT_ALPHA="${EXP_DHT_ALPHA:-10}"
EXP_DHT_BUCKET_K="${EXP_DHT_BUCKET_K:-20}"
EXP_DHT_PRIVATE_NET="${EXP_DHT_PRIVATE_NET:-1}"

if [ ! -f "$SWARM_KEY_HOST" ]; then
    echo "launch_node: swarm key not found at $SWARM_KEY_HOST" >&2
    exit 1
fi

# Idempotency: drop any stale container with this name first.
if docker inspect "$NODE_NAME" >/dev/null 2>&1; then
    docker rm -f "$NODE_NAME" >/dev/null
fi

node_results_dir="${RESULTS_DIR}/${NODE_NAME}"
mkdir -p "$node_results_dir"

run_args=(
    -d
    --name "$NODE_NAME"
    --network "$CONTAINER_NET"
    --ip "$NODE_IP"
    --cap-add NET_ADMIN                       # needed for tc/netem inside the netns
    -e "NODE_ROLE=${NODE_ROLE}"
    -e "EXP_DHT_ALPHA=${EXP_DHT_ALPHA}"
    -e "EXP_DHT_BUCKET_K=${EXP_DHT_BUCKET_K}"
    -e "EXP_DHT_PRIVATE_NET=${EXP_DHT_PRIVATE_NET}"
    # entrypoint.sh's SWARM_KEY_SRC default (/swarm.key) matches the docker-compose
    # pilot's mount point, NOT this one — must be set explicitly here to match
    # where the swarm key actually lands in THIS container (see -v below), or the
    # daemon silently skips pnet install.
    -e "SWARM_KEY_SRC=/data/swarm.key"
    -v "${SWARM_KEY_HOST}:/data/swarm.key:ro"
    -v "${node_results_dir}:/results"
)
[ -n "${BOOTSTRAP_MADDR:-}" ] && run_args+=( -e "BOOTSTRAP_MADDR=${BOOTSTRAP_MADDR}" )
[ -n "${CPU_LIMIT:-}" ] && run_args+=( --cpus "${CPU_LIMIT}" )
[ -n "${MEM_LIMIT:-}" ] && run_args+=( --memory "${MEM_LIMIT}" )

docker run "${run_args[@]}" "$KUBO_IMAGE" >/dev/null
echo "started ${NODE_NAME} role=${NODE_ROLE} ip=${NODE_IP} alpha=${EXP_DHT_ALPHA} k=${EXP_DHT_BUCKET_K}"

# --- netem: shape this node's own interface inside its network namespace -------
# Only meaningful for intra-host RTT (same-host containers are otherwise ~0ms);
# cross-host latency is the real geographic path over the WireGuard mesh.
if [ -n "${NETEM_DELAY:-}" ]; then
    pid="$(docker inspect -f '{{.State.Pid}}' "$NODE_NAME")"
    if [ -z "$pid" ] || [ "$pid" = "0" ]; then
        echo "launch_node: could not read PID for $NODE_NAME; skipping netem" >&2
        exit 1
    fi
    netem_args=( delay "${NETEM_DELAY}" )
    [ -n "${NETEM_JITTER:-}" ] && netem_args+=( "${NETEM_JITTER}" )
    [ -n "${NETEM_LOSS:-}" ] && netem_args+=( loss "${NETEM_LOSS}" )
    # The container's bridge (veth) endpoint is eth0.
    nsenter -t "$pid" -n tc qdisc replace dev eth0 root netem "${netem_args[@]}"
    echo "  netem eth0: ${netem_args[*]}"
fi
