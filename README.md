# IPFS DHT testbed: how Kademlia α and K shape lookup performance

Research software for my BSc senior project (work in progress). The project
measures how IPFS content lookup and delivery change when two Kademlia DHT
parameters are varied: query concurrency **α** and bucket size **K**. Delivery
is also compared against a plain HTTP server as a reference point.

## Structure

- `ipfs_dht_harness/`: Go tool that runs DHT lookups and records latency, hops
  and messages per lookup. Includes tests and two Python analysis scripts.
  - `testbed/kubo-patch/`: patch that makes α and K configurable in Kubo.
  - `testbed/`: Docker image and a single-host compose setup.
- `ipfs_experiment_bundle4/ansible/`: Ansible pipeline that deploys a private
  IPFS network across cloud servers (WireGuard mesh, ~125 Kubo containers per
  host, netem latency).

## Usage

```sh
cd ipfs_experiment_bundle4/ansible
../../ipfs_dht_harness/testbed/gen-swarm-key.sh roles/kubo_fleet/files/swarm.key
ansible-playbook -i inventory/pilot.ini fleet-image.yml    # build the patched Kubo image
ansible-playbook -i inventory/pilot.ini fleet-mesh.yml     # WireGuard mesh
ansible-playbook -i inventory/pilot.ini fleet-up.yml       # start the nodes
ansible-playbook -i inventory/pilot.ini fleet-run.yml      # run trials
ansible-playbook -i inventory/pilot.ini fleet-collect.yml  # fetch + analyse
ansible-playbook -i inventory/pilot.ini fleet-down.yml     # tear down
```

Fill in your own hosts in the inventory files first.

## Notable bugs found and fixed

- **Private network silently dead.** `ipfs init --profile server` adds
  `10.0.0.0/8` to `Swarm.AddrFilters`, so on a 10.x testbed every node refused
  to dial every other node while still appearing healthy. Fixed by clearing the
  filters after init.
- **ipvlan cannot attach to WireGuard.** WireGuard interfaces have no MAC
  address, so ipvlan/macvlan fail on them. Switched to a routed bridge per host.
- **Kubo exits on a private network.** Kubo v0.43 fetches a public AutoConf URL
  at startup and exits when it cannot. AutoConf is disabled in the entrypoint.
- **Lock race on startup.** Offline `ipfs` commands compete with the daemon for
  `repo.lock`. Payloads are now added through the daemon API.
- **Timeouts counted as successes.** curl exits 0 on an HTTP 504 from the
  gateway, so success now requires HTTP 200.
- **Unreadable CSV keys.** Raw binary Kademlia keys broke the CSV output. keys
  are now hex-encoded.

## Requirements

Go 1.26, Python 3.11, Ansible, Docker, WireGuard, Kubo v0.43.0.
