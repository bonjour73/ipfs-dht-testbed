#!/usr/bin/env bash
set -euo pipefail

# Run on each leecher after the three site CIDs are known.
# Usage: ./run_design_a_experiments.sh <text_cid> <image_cid> <large_cid> <leecher_region> <run_count> <mode> [gateway_base_url]
# mode: curl | selenium

if [[ $# -lt 6 || $# -gt 7 ]]; then
  echo "Usage: $0 <text_cid> <image_cid> <large_cid> <leecher_region> <run_count> <mode> [gateway_base_url]" >&2
  exit 1
fi

TEXT_CID="$1"
IMAGE_CID="$2"
LARGE_CID="$3"
LEECHER_REGION="$4"
RUN_COUNT="$5"
MODE="$6"
GATEWAY_BASE_URL="${7:-http://127.0.0.1:8080}"
RESULT_DIR="/opt/ipfs-bench/results"
mkdir -p "$RESULT_DIR"

case "$MODE" in
  curl)
    /opt/ipfs-bench/bench_gateway_curl.sh "$TEXT_CID" text "$LEECHER_REGION" "$RUN_COUNT" "$RESULT_DIR/text_${LEECHER_REGION}_curl.csv" "$GATEWAY_BASE_URL"
    /opt/ipfs-bench/bench_gateway_curl.sh "$IMAGE_CID" image "$LEECHER_REGION" "$RUN_COUNT" "$RESULT_DIR/image_${LEECHER_REGION}_curl.csv" "$GATEWAY_BASE_URL"
    /opt/ipfs-bench/bench_gateway_curl.sh "$LARGE_CID" large "$LEECHER_REGION" "$RUN_COUNT" "$RESULT_DIR/large_${LEECHER_REGION}_curl.csv" "$GATEWAY_BASE_URL"
    ;;
  selenium)
    PYTHON_BIN="/opt/ipfs-bench/venv/bin/python3"
    if [[ ! -x "$PYTHON_BIN" ]]; then
      echo "Selenium environment not installed. Re-run Ansible with install_browser_stack=true." >&2
      exit 1
    fi
    "$PYTHON_BIN" /opt/ipfs-bench/bench_gateway_selenium.py "$TEXT_CID" text "$LEECHER_REGION" "$RUN_COUNT" "$RESULT_DIR/text_${LEECHER_REGION}_selenium.csv" "$GATEWAY_BASE_URL"
    "$PYTHON_BIN" /opt/ipfs-bench/bench_gateway_selenium.py "$IMAGE_CID" image "$LEECHER_REGION" "$RUN_COUNT" "$RESULT_DIR/image_${LEECHER_REGION}_selenium.csv" "$GATEWAY_BASE_URL"
    "$PYTHON_BIN" /opt/ipfs-bench/bench_gateway_selenium.py "$LARGE_CID" large "$LEECHER_REGION" "$RUN_COUNT" "$RESULT_DIR/large_${LEECHER_REGION}_selenium.csv" "$GATEWAY_BASE_URL"
    ;;
  *)
    echo "mode must be curl or selenium" >&2
    exit 1
    ;;
esac
