#!/usr/bin/env sh
set -eu

CID="${1:?usage: measure_once.sh <cid> [trial_num] [out_path]}"
TRIAL="${2:-1}"
OUT="${3:-${MEASURE_OUT:-/results/run.csv}}"

# Bootstrap multiaddr: prefer BOOTSTRAP_MADDR (how the fleet path — launch_node.sh
# — hands it to every container at creation), falling back to the shared-file
# convention for manual/pilot use (see entrypoint.sh wait_for_bootstrap_addr).
BOOT="${BOOTSTRAP_MADDR:-}"
if [ -z "$BOOT" ] && [ -f "${SHARED:-/shared}/bootstrap.addr" ]; then
	BOOT="$(cat "${SHARED:-/shared}/bootstrap.addr")"
fi
: "${BOOT:?measure_once: no bootstrap multiaddr (BOOTSTRAP_MADDR unset and no ${SHARED:-/shared}/bootstrap.addr)}"

mkdir -p "$(dirname "$OUT")"

exec dhtharness \
	-bootstrap "$BOOT" \
	-privatenet \
	-swarmkey "${SWARM_KEY_SRC:-/swarm.key}" \
	-cid "$CID" \
	-alpha "${EXP_DHT_ALPHA:-10}" \
	-k "${EXP_DHT_BUCKET_K:-20}" \
	-trials 1 \
	-trial-start "$TRIAL" \
	-settle "${HARNESS_SETTLE:-5s}" \
	-append \
	-out "$OUT"
