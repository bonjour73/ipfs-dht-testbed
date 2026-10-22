#!/usr/bin/env bash
set -euo pipefail

GATEWAY_URL="${1:-http://127.0.0.1:8080}"
API_ADDR="${2:-127.0.0.1:5001}"
SWARM_TCP_PORT="${3:-4001}"

echo "== systemd =="
systemctl --no-pager --full status ipfs || true

echo "== listeners =="
ss -lntup | grep -E ":(${SWARM_TCP_PORT}|8080|5001)\b" || true

echo "== gateway health =="
curl -fsS "${GATEWAY_URL%/}/ipfs/bafybeigdyrzt5sfp7udm7hu76hl6s5w6yt7n6d6z5dyomf4zqxj6sw5g3e" >/dev/null && echo gateway_ok || echo gateway_fetch_failed

echo "== ipfs id =="
/opt/ipfs-bench/ipfs_helpers.sh id

echo "== swarm peers =="
/opt/ipfs-bench/ipfs_helpers.sh peers || true

echo "== rpc version =="
curl -fsS -X POST "http://${API_ADDR}/api/v0/version" || true
