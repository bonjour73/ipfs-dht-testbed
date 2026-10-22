#!/usr/bin/env bash
set -euo pipefail

CID="QmZTPASM1PihVRJSeVXm8kLBuBy14pNpFFUGvZYJvEdgeM"
BASE="http://127.0.0.1:8080/ipfs/${CID}"

URLS=(
  "${BASE}/"
  "${BASE}/assets/index-BdHSCtFT.css"
  "${BASE}/assets/index-D7PpoB-I.js"
  "${BASE}/assets/hero-01.jpg"
  "${BASE}/assets/hero-02.jpg"
  "${BASE}/assets/gallery-01.jpg"
  "${BASE}/assets/gallery-02.jpg"
  "${BASE}/assets/gallery-03.jpg"
  "${BASE}/assets/gallery-04.jpg"
)

echo "run,timestamp,total_bytes,elapsed_seconds" > /root/cold_full_site_results.csv

for i in 1 2 3 4 5; do
  systemctl stop ipfs
  rm -rf /var/lib/ipfs
  mkdir -p /var/lib/ipfs
  chown -R ipfs:ipfs /var/lib/ipfs
  sudo -u ipfs IPFS_PATH=/var/lib/ipfs ipfs init >/dev/null
  systemctl start ipfs
  sleep 10

  start=$(date +%s.%N)
  total_bytes=0

  for url in "${URLS[@]}"; do
    bytes=$(curl -o /dev/null -s -w "%{size_download}" "$url")
    total_bytes=$((total_bytes + bytes))
  done

  end=$(date +%s.%N)
  elapsed=$(python3 - <<PY
start=$start
end=$end
print(end-start)
PY
)

  echo "${i},$(date -u +%FT%TZ),${total_bytes},${elapsed}" >> /root/cold_full_site_results.csv
  sleep 5
done
