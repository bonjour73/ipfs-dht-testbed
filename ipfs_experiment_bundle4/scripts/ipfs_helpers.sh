#!/usr/bin/env bash
set -euo pipefail

export IPFS_PATH="${IPFS_PATH:-/var/lib/ipfs}"
IPFS_USER="${IPFS_USER:-ipfs}"

cmd="${1:-}"
shift || true

case "$cmd" in
  id)
    sudo -u "$IPFS_USER" IPFS_PATH="$IPFS_PATH" ipfs id
    ;;
  peers)
    sudo -u "$IPFS_USER" IPFS_PATH="$IPFS_PATH" ipfs swarm peers
    ;;
  connect)
    sudo -u "$IPFS_USER" IPFS_PATH="$IPFS_PATH" ipfs swarm connect "$1"
    ;;
  pin)
    sudo -u "$IPFS_USER" IPFS_PATH="$IPFS_PATH" ipfs pin add "$1"
    ;;
  cat)
    sudo -u "$IPFS_USER" IPFS_PATH="$IPFS_PATH" ipfs cat "$1"
    ;;
  get)
    sudo -u "$IPFS_USER" IPFS_PATH="$IPFS_PATH" ipfs get "$1"
    ;;
  providers)
    sudo -u "$IPFS_USER" IPFS_PATH="$IPFS_PATH" ipfs routing findprovs "$1"
    ;;
  refs)
    sudo -u "$IPFS_USER" IPFS_PATH="$IPFS_PATH" ipfs refs -r "$1"
    ;;
  bitswap)
    sudo -u "$IPFS_USER" IPFS_PATH="$IPFS_PATH" ipfs bitswap stat
    ;;
  repo-gc)
    sudo -u "$IPFS_USER" IPFS_PATH="$IPFS_PATH" ipfs repo gc
    ;;
  *)
    echo "Usage: $0 {id|peers|connect <multiaddr>|pin <cid>|cat <cid>|get <cid>|providers <cid>|refs <cid>|bitswap|repo-gc}" >&2
    exit 1
    ;;
esac
