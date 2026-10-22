# Patched-Kubo + measurement-harness image for the private α/K testbed.
ARG GO_VERSION=1.26
FROM golang:${GO_VERSION}-bookworm AS build

# --- build the patched Kubo -------------------------------------------------
ARG KUBO_VERSION=v0.43.0
RUN git clone --depth 1 --branch ${KUBO_VERSION} https://github.com/ipfs/kubo /kubo
WORKDIR /kubo
# The α/K env-config helper (full file), then the wiring diff for the three
# construction sites (Concurrency/BucketSize + private-net filters).
# See testbed/kubo-patch/PATCH_INSTRUCTIONS.md for how the diff is produced.
COPY testbed/kubo-patch/config/dht_experiment.go /kubo/config/dht_experiment.go
COPY testbed/kubo-patch/kubo_dht_experiment.patch /tmp/exp.patch
RUN git apply --verbose --include='core/node/libp2p/*' --include='routing/*' --include='core/node/provider.go' /tmp/exp.patch \
	&& grep -q 'WithReplicationFactor(config.DHTBucketSize())' core/node/provider.go \
	&& gofmt -l config/dht_experiment.go \
	&& go build -o /out/ipfs ./cmd/ipfs

# --- build the measurement harness -----------------------------------------
WORKDIR /harness
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN go build -o /out/dhtharness .

# --- runtime ---------------------------------------------------------------
FROM debian:bookworm-slim
# curl: needed by baseline_fetch.sh (the centralized-baseline race) to time both
# the cold IPFS gateway delivery and the centralized nginx fetch.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates iproute2 curl \
	&& rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ipfs /usr/local/bin/ipfs
COPY --from=build /out/dhtharness /usr/local/bin/dhtharness
COPY testbed/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY testbed/scripts/seed_once.sh /usr/local/bin/seed_once.sh
COPY testbed/scripts/measure_once.sh /usr/local/bin/measure_once.sh
COPY testbed/scripts/baseline_fetch.sh /usr/local/bin/baseline_fetch.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/seed_once.sh \
	/usr/local/bin/measure_once.sh /usr/local/bin/baseline_fetch.sh \
	&& mkdir -p /data/ipfs /shared
ENV IPFS_PATH=/data/ipfs
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
