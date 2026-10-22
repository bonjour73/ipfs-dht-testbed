#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <ssh_user> <host1> [host2 ...]" >&2
  exit 1
fi

SSH_USER="$1"
shift
mkdir -p ./collected_results

for host in "$@"; do
  mkdir -p "./collected_results/$host"
  scp -r "${SSH_USER}@${host}:/opt/ipfs-bench/results/" "./collected_results/$host/"
done
