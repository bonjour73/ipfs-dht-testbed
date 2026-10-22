#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 5 || $# -gt 6 ]]; then
  echo "Usage: $0 <cid> <page_name> <leecher_region> <run_count> <output_csv> [gateway_base_url]" >&2
  exit 1
fi

CID="$1"
PAGE_NAME="$2"
LEECHER_REGION="$3"
RUN_COUNT="$4"
OUTPUT_CSV="$5"
GATEWAY_BASE_URL="${6:-${CURL_GATEWAY_URL:-http://127.0.0.1:8080}}"
REQUEST_TIMEOUT="${BENCH_REQUEST_TIMEOUT_SECONDS:-120}"
URL="${GATEWAY_BASE_URL%/}/ipfs/${CID}/"

mkdir -p "$(dirname "$OUTPUT_CSV")"
if [[ ! -f "$OUTPUT_CSV" ]]; then
  echo "timestamp,page,leecher_region,run_index,success,curl_exit_code,http_code,time_namelookup,time_connect,time_starttransfer,time_total,size_download,remote_ip,url,error_message" > "$OUTPUT_CSV"
fi

for i in $(seq 1 "$RUN_COUNT"); do
  tmp_metrics=$(mktemp)
  tmp_error=$(mktemp)
  if curl -o /dev/null -sS     --connect-timeout 15     --max-time "$REQUEST_TIMEOUT"     -w "%{http_code},%{time_namelookup},%{time_connect},%{time_starttransfer},%{time_total},%{size_download},%{remote_ip}"     "$URL" >"$tmp_metrics" 2>"$tmp_error"; then
    metrics=$(cat "$tmp_metrics")
    error_message=""
    success=1
    curl_exit_code=0
  else
    curl_exit_code=$?
    metrics="000,0,0,0,0,0,"
    error_message=$(tr '
' ' ' < "$tmp_error" | tr ',' ';')
    success=0
  fi

  echo "$(date -u +%FT%TZ),${PAGE_NAME},${LEECHER_REGION},${i},${success},${curl_exit_code},${metrics},${URL},${error_message}" >> "$OUTPUT_CSV"
  rm -f "$tmp_metrics" "$tmp_error"
  sleep 2
done
