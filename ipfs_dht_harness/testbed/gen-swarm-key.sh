#!/usr/bin/env sh
# Generate a pnet swarm.key (v1 / base16). Every node in the private testbed
# must share the SAME swarm.key; nodes without it are refused, which walls the
# network off from the public IPFS network.
set -eu

out="${1:-swarm.key}"

if command -v openssl >/dev/null 2>&1; then
	hex=$(openssl rand -hex 32)
else
	# portable fallback
	hex=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi

{
	printf '/key/swarm/psk/1.0.0/\n'
	printf '/base16/\n'
	printf '%s\n' "$hex"
} >"$out"

echo "wrote $out (share this identical file with every node)"
