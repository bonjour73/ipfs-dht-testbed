#!/usr/bin/env bash
set -euo pipefail

: "${CID:?}" "${TRIAL:?}" "${STATE_DIR:?}"
PARALLEL="${MEASURE_PARALLEL:-16}"
nodes_list="${STATE_DIR}/nodes.list"

[ -f "$nodes_list" ] || { echo "run_trial_measure: $nodes_list not found (did fleet-up.yml run?)" >&2; exit 1; }

mapfile -t leechers < <(awk '$3=="leecher"{print $1}' "$nodes_list")
[ "${#leechers[@]}" -gt 0 ] || { echo "run_trial_measure: no leecher-role nodes in $nodes_list" >&2; exit 1; }

results="$(
    printf '%s\n' "${leechers[@]}" | xargs -P "$PARALLEL" -I{} sh -c '
        if docker exec "{}" measure_once.sh "$1" "$2" >/dev/null 2>&1; then
            echo "OK {}"
        else
            echo "FAIL {}"
        fi
    ' _ "$CID" "$TRIAL"
)"

ok_count="$(printf '%s\n' "$results" | grep -c '^OK ' || true)"
fail_count="$(printf '%s\n' "$results" | grep -c '^FAIL ' || true)"
if [ "$fail_count" -gt 0 ]; then
    echo "trial=${TRIAL} FAILED leechers: $(printf '%s\n' "$results" | awk '/^FAIL /{print $2}' | paste -sd, -)" >&2
fi

echo "trial=${TRIAL} measured ${ok_count}/${#leechers[@]} leecher(s) on this host (${fail_count} failed), cid=${CID}"
