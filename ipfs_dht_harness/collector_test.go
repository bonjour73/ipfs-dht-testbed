package main

import (
	"context"
	"encoding/hex"
	"testing"
	"time"

	"github.com/ipfs/go-cid"
	libp2p "github.com/libp2p/go-libp2p"
	kaddht "github.com/libp2p/go-libp2p-kad-dht"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer"
	mh "github.com/multiformats/go-multihash"
)

func newTestNode(t *testing.T, alpha, k int) (host.Host, *kaddht.IpfsDHT) {
	t.Helper()
	h, err := libp2p.New(libp2p.ListenAddrStrings("/ip4/127.0.0.1/tcp/0"))
	if err != nil {
		t.Fatalf("libp2p.New: %v", err)
	}
	d, err := kaddht.New(h,
		kaddht.Mode(kaddht.ModeServer),
		kaddht.ProtocolPrefix("/dhtharness-test"),
		kaddht.Concurrency(alpha),
		kaddht.BucketSize(k),
	)
	if err != nil {
		t.Fatalf("kaddht.New: %v", err)
	}
	return h, d
}

func TestInstrumentedLookupLocalDHT(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	const (
		N     = 4 // mesh nodes (fill + provider)
		alpha = 3
		k     = 20
	)

	// Build the mesh and fully connect it so routing tables populate.
	hosts := make([]host.Host, N)
	dhts := make([]*kaddht.IpfsDHT, N)
	for i := 0; i < N; i++ {
		hosts[i], dhts[i] = newTestNode(t, alpha, k)
		defer hosts[i].Close()
		defer dhts[i].Close()
	}
	for i := 0; i < N; i++ {
		for j := i + 1; j < N; j++ {
			ai := peer.AddrInfo{ID: hosts[j].ID(), Addrs: hosts[j].Addrs()}
			if err := hosts[i].Connect(ctx, ai); err != nil {
				t.Fatalf("connect %d->%d: %v", i, j, err)
			}
		}
	}
	for _, d := range dhts {
		if err := d.Bootstrap(ctx); err != nil {
			t.Fatalf("bootstrap: %v", err)
		}
	}
	time.Sleep(2 * time.Second) // identify + routing-table refresh settle

	// A stable content id, provided by mesh node 1.
	digest, err := mh.Sum([]byte("lookup-verify"), mh.SHA2_256, -1)
	if err != nil {
		t.Fatalf("multihash: %v", err)
	}
	c := cid.NewCidV1(cid.Raw, digest)

	provider := hosts[1].ID()
	if err := dhts[1].Provide(ctx, c, true); err != nil {
		t.Fatalf("provide: %v", err)
	}
	time.Sleep(500 * time.Millisecond)

	qh, qd := newTestNode(t, alpha, k)
	defer qh.Close()
	defer qd.Close()
	for i := 0; i < N; i++ {
		ai := peer.AddrInfo{ID: hosts[i].ID(), Addrs: hosts[i].Addrs()}
		if err := qh.Connect(ctx, ai); err != nil {
			t.Fatalf("querier connect ->%d: %v", i, err)
		}
	}
	if err := qd.Bootstrap(ctx); err != nil {
		t.Fatalf("querier bootstrap: %v", err)
	}
	time.Sleep(1 * time.Second)

	mets, provs, err := RunInstrumentedLookup(ctx, qd, c, 1)
	if err != nil {
		t.Fatalf("RunInstrumentedLookup: %v", err)
	}

	// 1) The DHT actually resolved the provider.
	foundProvider := false
	for _, p := range provs {
		if p.ID == provider {
			foundProvider = true
		}
	}
	if !foundProvider {
		t.Fatalf("provider %s not found; got %v", provider, provs)
	}

	// 2) the collector captured the lookup with sane metrics.
	if len(mets) == 0 {
		t.Fatalf("no lookup metrics captured — the collector did not observe the lookup")
	}
	m := mets[0]
	m.Alpha, m.K = alpha, k
	t.Logf("captured lookup: latency=%.2fms heard=%d queried=%d unreachable=%d hops=%d terminate=%q alpha=%d k=%d",
		m.LatencyMS, m.PeersHeard, m.PeersQueried, m.Unreachable, m.Hops, m.Terminate, m.Alpha, m.K)

	if m.PeersQueried < 1 {
		t.Errorf("expected at least 1 peer queried, got %d", m.PeersQueried)
	}
	if m.LatencyMS <= 0 {
		t.Errorf("expected positive latency, got %.3f", m.LatencyMS)
	}
	if m.Terminate == "" {
		t.Errorf("expected a termination reason, got empty")
	}
	// The key must be printable hex, not raw binary Kademlia bytes. Empty is allowed (some events carry no key),
	// but any content must decode as hex.
	if m.Key != "" {
		if _, err := hex.DecodeString(m.Key); err != nil {
			t.Errorf("key field is not printable hex (%q): %v", m.Key, err)
		}
	}
}

// TestMaxDepth checks the referral-tree depth helper in isolation.
func TestMaxDepth(t *testing.T) {
	// Build ids a<-b<-c<-d chain plus a stray seed e.
	a := peer.ID("a")
	b := peer.ID("b")
	c := peer.ID("c")
	d := peer.ID("d")
	parent := map[peer.ID]peer.ID{
		b: a, // b heard from a
		c: b,
		d: c,
	}
	if got := maxDepth(parent); got != 3 {
		t.Errorf("chain depth: want 3, got %d", got)
	}
	if got := maxDepth(map[peer.ID]peer.ID{}); got != 0 {
		t.Errorf("empty depth: want 0, got %d", got)
	}
}
