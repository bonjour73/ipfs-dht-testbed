#!/usr/bin/env bash
set -euo pipefail

CID="QmZTPASM1PihVRJSeVXm8kLBuBy14pNpFFUGvZYJvEdgeM"
URL="http://127.0.0.1:8080/ipfs/${CID}/assets/hero-01.jpg"

echo "run,timestamp,size_download,ttfb,total" > /root/cold_hero_results.csv

for i in 1 2 3 4 5; do
  systemctl stop ipfs
  rm -rf /var/lib/ipfs
  mkdir -p /var/lib/ipfs
  chown -R ipfs:ipfs /var/lib/ipfs
  sudo -u ipfs IPFS_PATH=/var/lib/ipfs ipfs init >/dev/null
  systemctl start ipfs
  sleep 10

  result=$(curl -o /dev/null -s \
    -w "${i},%{time_starttransfer},%{time_total},%{size_download}" \
    "$URL")

  # reorder to match header
  IFS=',' read -r run ttfb total size <<< "$result"
  echo "${run},$(date -u +%FT%TZ),${size},${ttfb},${total}" >> /root/cold_hero_results.csv

  sleep 5
done
