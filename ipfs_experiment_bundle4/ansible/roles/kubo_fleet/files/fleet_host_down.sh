#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NET="${CONTAINER_NET:-fleetnet}"
STATE_DIR="${STATE_DIR:-/var/run/kubo_fleet}"
pattern="node-${REGION:-}"

mapfile -t names < <(docker ps -a --format '{{.Names}}' | grep "^${pattern}" || true)
if [ "${#names[@]}" -gt 0 ]; then
    docker rm -f "${names[@]}" >/dev/null
    echo "removed ${#names[@]} node container(s)"
else
    echo "no node containers matched ${pattern}*"
fi

if docker network inspect "$CONTAINER_NET" >/dev/null 2>&1; then
    docker network rm "$CONTAINER_NET" >/dev/null || true
    echo "removed network $CONTAINER_NET"
fi

rm -f "${STATE_DIR}/nodes.list" "${STATE_DIR}/bootstrap.maddr" 2>/dev/null || true
echo "host down complete"
