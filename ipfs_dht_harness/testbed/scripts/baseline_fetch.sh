#!/usr/bin/env sh
set -eu

CID="${1:?usage: baseline_fetch.sh <cid> <central_url> [trial_num] [out_path]}"
CENTRAL_URL="${2:?usage: baseline_fetch.sh <cid> <central_url> [trial_num] [out_path]}"
TRIAL="${3:-1}"
OUT="${4:-${BASELINE_OUT:-/results/baseline.csv}}"
GW="${IPFS_GATEWAY:-http://127.0.0.1:8080}"
TIMEOUT="${FETCH_TIMEOUT:-120}"
ALPHA="${EXP_DHT_ALPHA:-10}"
K="${EXP_DHT_BUCKET_K:-20}"

mkdir -p "$(dirname "$OUT")"
if [ ! -s "$OUT" ]; then
	echo "trial,ipfs_success,ipfs_ttfb_s,ipfs_total_s,ipfs_bytes,ipfs_http,central_success,central_ttfb_s,central_total_s,central_bytes,central_http,alpha,k" >"$OUT"
fi

# curl -w fields, space-separated: TTFB, total, bytes, http-code.
fmt='%{time_starttransfer} %{time_total} %{size_download} %{http_code}'

# --- IPFS cold delivery -------------------------------------------------------
if out=$(curl -o /dev/null -sS --max-time "$TIMEOUT" -w "$fmt" "${GW}/ipfs/${CID}" 2>/dev/null); then
	# shellcheck disable=SC2086 # deliberate word-split of the 4 curl fields
	set -- $out
	i_ok=1 i_ttfb="$1" i_total="$2" i_bytes="$3" i_http="$4"
	# curl exits 0 on HTTP errors (e.g. the gateway's 30s-timeout 504); only a
	# 200 is a real delivery.
	[ "$i_http" = "200" ] || i_ok=0
else
	i_ok=0 i_ttfb=0 i_total=0 i_bytes=0 i_http=000
fi

# --- centralized delivery -----------------------------------------------------
# NOTE: the positional params were consumed by `set --` above; CID / CENTRAL_URL
# / TRIAL / OUT were already saved into named vars, so this is safe.
if out=$(curl -o /dev/null -sS --max-time "$TIMEOUT" -w "$fmt" "$CENTRAL_URL" 2>/dev/null); then
	# shellcheck disable=SC2086
	set -- $out
	c_ok=1 c_ttfb="$1" c_total="$2" c_bytes="$3" c_http="$4"
	[ "$c_http" = "200" ] || c_ok=0
else
	c_ok=0 c_ttfb=0 c_total=0 c_bytes=0 c_http=000
fi

echo "${TRIAL},${i_ok},${i_ttfb},${i_total},${i_bytes},${i_http},${c_ok},${c_ttfb},${c_total},${c_bytes},${c_http},${ALPHA},${K}" >>"$OUT"
