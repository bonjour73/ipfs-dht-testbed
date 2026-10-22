#!/usr/bin/env bash
set -euo pipefail

: "${TRIAL:?}" "${STATE_DIR:?}"
SEED_SIZE_BYTES="${SEED_SIZE_BYTES:-1048576}"
nodes_list="${STATE_DIR}/nodes.list"

[ -f "$nodes_list" ] || { echo "run_trial_seed: $nodes_list not found (did fleet-up.yml run?)" >&2; exit 1; }

mapfile -t seeders < <(awk '$3=="seeder"{print $1}' "$nodes_list")
[ "${#seeders[@]}" -gt 0 ] || { echo "run_trial_seed: no seeder-role nodes in $nodes_list" >&2; exit 1; }

idx=$(( (TRIAL - 1) % ${#seeders[@]} ))
container="${seeders[$idx]}"

cid="$(docker exec "$container" seed_once.sh "$SEED_SIZE_BYTES")"
[ -n "$cid" ] || { echo "run_trial_seed: seed_once.sh produced no CID on $container" >&2; exit 1; }

echo "trial=${TRIAL} seeded container=${container} cid=${cid}" >&2
echo "$cid"
