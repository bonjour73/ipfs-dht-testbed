#!/usr/bin/env sh
set -eu

ROLE="${ROLE:-${NODE_ROLE:-node}}"
IPFS_PATH="${IPFS_PATH:-/data/ipfs}"
export IPFS_PATH
SHARED="${SHARED:-/shared}"
SWARM_KEY_SRC="${SWARM_KEY_SRC:-/swarm.key}"
export EXP_DHT_PRIVATE_NET="${EXP_DHT_PRIVATE_NET:-1}"
# Custom DHT protocol prefix, read by the patched Kubo binary (config.DHTProtocolPrefix)
# AND the harness. A non-"/ipfs" prefix is REQUIRED for K != 20 (kad-dht Validate()
# only enforces K==20 on the Amino default prefix) and isolates the testbed at the
# protocol layer. Node and measurer must share it; both default to /exp.
export EXP_DHT_PROTOCOL_PREFIX="${EXP_DHT_PROTOCOL_PREFIX:-/exp}"
export LIBP2P_FORCE_PNET=1

log() { echo "[entrypoint][$ROLE] $*" >&2; }

mkdir -p "$SHARED"

configure_repo() {
	if [ ! -f "$IPFS_PATH/config" ]; then
		log "ipfs init"
		ipfs init --profile server >/dev/null 2>&1
	fi
	if [ -f "$SWARM_KEY_SRC" ]; then
		cp "$SWARM_KEY_SRC" "$IPFS_PATH/swarm.key"
		log "installed swarm.key (private network)"
	else
		log "FATAL: no swarm.key at $SWARM_KEY_SRC — refusing to run unisolated (LIBP2P_FORCE_PNET=1)"
		exit 1
	fi
	# Pure private DHT: no public bootstrap, dht routing, no mDNS/relay noise.
	ipfs bootstrap rm --all >/dev/null 2>&1 || true
	n=0
	until [ "$(ipfs config AutoConf.Enabled 2>/dev/null)" = "false" ]; do
		ipfs config --json AutoConf.Enabled false >/dev/null 2>&1 || true
		n=$((n + 1))
		[ "$n" -gt 30 ] && { log "FATAL: could not set AutoConf.Enabled=false"; exit 1; }
		sleep 1
	done
	ipfs config Routing.Type dht
	ipfs config --json Addresses.Swarm '["/ip4/0.0.0.0/tcp/4001"]'
	ipfs config --json Swarm.AddrFilters '[]'
	ipfs config --json Addresses.NoAnnounce '[]'
	# Gateway: needed for the centralized-baseline race's cold IPFS content
	# fetch (baseline_fetch.sh curls http://127.0.0.1:8080/ipfs/<cid>). This is
	# the Kubo default, set explicitly so the race doesn't depend on an
	# unstated default.
	ipfs config Addresses.Gateway /ip4/127.0.0.1/tcp/8080
	ipfs config --json Discovery.MDNS.Enabled false >/dev/null 2>&1 || true
	ipfs config --json Swarm.RelayClient.Enabled false >/dev/null 2>&1 || true
	ipfs config --json Swarm.RelayService.Enabled false >/dev/null 2>&1 || true
	ipfs config --json Swarm.DisableNatPortMap true >/dev/null 2>&1 || true
}

apply_netem() {
	[ -n "${NETEM_DELAY:-}" ] || return 0
	if command -v tc >/dev/null 2>&1; then
		if tc qdisc add dev eth0 root netem delay "$NETEM_DELAY" 2>/dev/null; then
			log "netem delay $NETEM_DELAY on eth0"
		else
			log "netem failed (needs cap_net_admin + iproute2)"
		fi
	fi
}

wait_for_bootstrap_addr() {
	if [ -n "${BOOTSTRAP_MADDR:-}" ]; then
		echo "$BOOTSTRAP_MADDR"
		return 0
	fi
	i=0
	while [ ! -f "$SHARED/bootstrap.addr" ]; do
		i=$((i + 1))
		[ "$i" -gt 180 ] && {
			log "gave up waiting for bootstrap.addr (no BOOTSTRAP_MADDR env and no $SHARED/bootstrap.addr file)"
			return 1
		}
		sleep 1
	done
	cat "$SHARED/bootstrap.addr"
}

configure_repo
apply_netem

case "$ROLE" in
bootstrap)
	ipfs daemon --migrate=false &
	dpid=$!
	i=0
	while ! ipfs --api="/ip4/127.0.0.1/tcp/5001" swarm addrs local >/dev/null 2>&1; do
		i=$((i + 1))
		if ! kill -0 "$dpid" 2>/dev/null; then
			log "FATAL: bootstrap daemon died before its API came up"
			wait "$dpid"
			exit 1
		fi
		[ "$i" -gt 60 ] && {
			log "FATAL: bootstrap daemon API not ready after 60s"
			exit 1
		}
		sleep 1
	done
	pid=$(ipfs --api="/ip4/127.0.0.1/tcp/5001" id -f '<id>')
	echo "/dns4/bootstrap/tcp/4001/p2p/$pid" >"$SHARED/bootstrap.addr"
	log "published bootstrap addr: $(cat "$SHARED/bootstrap.addr")"
	wait "$dpid"
	;;
node | leecher)
	baddr=$(wait_for_bootstrap_addr) || exit 1
	ipfs bootstrap add "$baddr" >/dev/null 2>&1 || true
	log "using bootstrap $baddr"
	exec ipfs daemon --migrate=false
	;;
seeder)
	baddr=$(wait_for_bootstrap_addr) || exit 1
	ipfs bootstrap add "$baddr" >/dev/null 2>&1 || true
	# Prepare the payload BEFORE the daemon starts (offline `ipfs add` here would
	# fight the daemon for repo.lock). We only create the file now; the actual `ipfs add` runs
	# against the daemon API once it's up.
	payload="${SEED_PAYLOAD:-/data/payload.bin}"
	if [ ! -f "$payload" ]; then
		head -c "${SEED_SIZE_BYTES:-1048576}" /dev/urandom >"$payload"
	fi
	ipfs daemon --migrate=false &
	dpid=$!
	i=0
	while ! ipfs --api="/ip4/127.0.0.1/tcp/5001" swarm addrs local >/dev/null 2>&1; do
		i=$((i + 1))
		if ! kill -0 "$dpid" 2>/dev/null; then
			log "FATAL: seeder daemon died before its API came up"
			wait "$dpid"
			exit 1
		fi
		[ "$i" -gt 60 ] && {
			log "FATAL: seeder daemon API not ready after 60s"
			exit 1
		}
		sleep 1
	done
	sleep "${SEED_SETTLE:-15}"
	# All commands below explicitly target the running daemon API, so they
	# never touch repo.lock.
	cid=$(ipfs --api="/ip4/127.0.0.1/tcp/5001" add -q --cid-version 1 "$payload") || {
		log "FATAL: ipfs add failed"
		exit 1
	}
	log "seeded CID $cid; providing to DHT..."
	ipfs --api="/ip4/127.0.0.1/tcp/5001" routing provide "$cid" >/dev/null 2>&1 \
		|| ipfs --api="/ip4/127.0.0.1/tcp/5001" dht provide "$cid" >/dev/null 2>&1 || true
	echo "$cid" >"$SHARED/target.cid"
	log "wrote target.cid=$cid"
	wait "$dpid"
	;;
measurer)
	baddr=$(wait_for_bootstrap_addr) || exit 1
	# wait for the seeder to publish a CID
	i=0
	while [ ! -f "$SHARED/target.cid" ]; do
		i=$((i + 1))
		[ "$i" -gt 180 ] && {
			log "no target.cid appeared"
			exit 1
		}
		sleep 1
	done
	cid="${TARGET_CID:-$(cat "$SHARED/target.cid")}"
	log "measuring cid=$cid via bootstrap=$baddr (settle ${MEASURE_SETTLE:-20}s)"
	sleep "${MEASURE_SETTLE:-20}"
	# -protocol-prefix MUST match the nodes under test (they run the custom
	# prefix in private-net mode); mismatched prefixes never form a routing
	# table. Both default to /exp, so this stays in sync automatically.
	exec dhtharness \
		-bootstrap "$baddr" \
		-privatenet \
		-protocol-prefix "${EXP_DHT_PROTOCOL_PREFIX:-/exp}" \
		-swarmkey "$SWARM_KEY_SRC" \
		-cid "$cid" \
		-alpha "${EXP_DHT_ALPHA:-10}" \
		-k "${EXP_DHT_BUCKET_K:-20}" \
		-trials "${TRIALS:-30}" \
		-settle "${HARNESS_SETTLE:-10s}" \
		-out "${OUT:-/shared/run.csv}"
	;;
*)
	log "unknown ROLE=$ROLE"
	exit 2
	;;
esac
