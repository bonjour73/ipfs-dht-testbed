package config

import (
	"os"
	"strconv"
	"strings"
)

const (
	EnvDHTAlpha          = "EXP_DHT_ALPHA"
	EnvDHTBucketSize     = "EXP_DHT_BUCKET_K"
	EnvDHTPrivateNet     = "EXP_DHT_PRIVATE_NET"
	EnvDHTProtocolPrefix = "EXP_DHT_PROTOCOL_PREFIX"

	DefaultDHTAlpha          = 10 // amino.DefaultConcurrency
	DefaultDHTBucketSize     = 20 // amino.DefaultBucketSize
	DefaultDHTProtocolPrefix = "/exp"
)

func dhtEnvInt(name string, def int) int {
	if v := os.Getenv(name); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return def
}

// DHTAlpha returns the Kademlia query concurrency (alpha) to use.
func DHTAlpha() int { return dhtEnvInt(EnvDHTAlpha, DefaultDHTAlpha) }

// DHTBucketSize returns the Kademlia bucket size (K) to use.
func DHTBucketSize() int { return dhtEnvInt(EnvDHTBucketSize, DefaultDHTBucketSize) }

// DHTPrivateNet reports whether the private-network address filters should be
// used (EXP_DHT_PRIVATE_NET set to 1/true/yes/on). Off by default so public
// behaviour is unchanged.
func DHTPrivateNet() bool {
	switch os.Getenv(EnvDHTPrivateNet) {
	case "1", "true", "TRUE", "yes", "on":
		return true
	}
	return false
}

func DHTProtocolPrefix() string {
	p := strings.TrimSpace(os.Getenv(EnvDHTProtocolPrefix))
	if p == "" {
		return DefaultDHTProtocolPrefix
	}
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	return p
}
