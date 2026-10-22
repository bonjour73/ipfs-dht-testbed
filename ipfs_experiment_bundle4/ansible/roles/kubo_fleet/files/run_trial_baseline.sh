#!/usr/bin/env bash
set -euo pipefail

: "${CID:?}" "${TRIAL:?}" "${STATE_DIR:?}" "${CENTRAL_URL:?}"
PARALLEL="${MEASURE_PARALLEL:-16}"
nodes_list="${STATE_DIR}/nodes.list"

[ -f "$nodes_list" ] || { echo "run_trial_baseline: $nodes_list not found (did fleet-up.yml run?)" >&2; exit 1; }

mapfile -t leechers < <(awk '$3=="leecher"{print $1}' "$nodes_list")
[ "${#leechers[@]}" -gt 0 ] || { echo "run_trial_baseline: no leecher-role nodes in $nodes_list" >&2; exit 1; }

# OK/FAIL to stdout so the Ansible task surfaces per-host success counts (same
# rationale as run_trial_measure.sh); a few flaky containers must not abort the
# whole host's batch.
results="$(
    printf '%s\n' "${leechers[@]}" | xargs -P "$PARALLEL" -I{} sh -c '
        if docker exec "{}" baseline_fetch.sh "$1" "$2" "$3" >/dev/null 2>&1; then
            echo "OK {}"
        else
            echo "FAIL {}"
        fi
    ' _ "$CID" "$CENTRAL_URL" "$TRIAL"
)"

ok_count="$(printf '%s\n' "$results" | grep -c '^OK ' || true)"
fail_count="$(printf '%s\n' "$results" | grep -c '^FAIL ' || true)"
if [ "$fail_count" -gt 0 ]; then
    echo "trial=${TRIAL} baseline FAILED leechers: $(printf '%s\n' "$results" | awk '/^FAIL /{print $2}' | paste -sd, -)" >&2
fi

echo "trial=${TRIAL} baseline measured ${ok_count}/${#leechers[@]} leecher(s) on this host (${fail_count} failed), cid=${CID}"
