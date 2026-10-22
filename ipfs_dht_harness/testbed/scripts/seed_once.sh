#!/usr/bin/env sh
set -eu

SIZE_BYTES="${1:-${SEED_SIZE_BYTES:-1048576}}"
payload="$(mktemp /tmp/seed_once.XXXXXX)"
trap 'rm -f "$payload"' EXIT

head -c "$SIZE_BYTES" /dev/urandom >"$payload"
cid=$(ipfs add -q --cid-version 1 "$payload")
ipfs routing provide "$cid" >/dev/null 2>&1 || ipfs dht provide "$cid" >/dev/null 2>&1 || true
echo "$cid"
