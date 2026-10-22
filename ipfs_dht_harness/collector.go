package main

import (
	"context"
	"encoding/hex"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/ipfs/go-cid"
	kaddht "github.com/libp2p/go-libp2p-kad-dht"
	"github.com/libp2p/go-libp2p/core/peer"
)

// LookupMetrics is one fully-observed DHT lookup.
type LookupMetrics struct {
	ID           uuid.UUID
	Key          string
	LatencyMS    float64
	PeersHeard   int
	PeersQueried int
	Unreachable  int
	Hops         int
	Terminate    string
	// Alpha and K are filled in by the caller (they come from the env patch,
	// not from the event stream).
	Alpha int
	K     int
}

type lookupAgg struct {
	key         string
	start       time.Time
	end         time.Time
	heard       map[peer.ID]struct{}
	queried     map[peer.ID]struct{} // waiting + queried + unreachable
	unreachable map[peer.ID]struct{}
	parent      map[peer.ID]peer.ID // child -> the peer who told us about it
	terminate   string
}

// Collector aggregates a LookupEvent stream into completed LookupMetrics.
// It is safe for a single reader goroutine; process() is not called concurrently
// with itself.
type Collector struct {
	mu   sync.Mutex
	aggs map[uuid.UUID]*lookupAgg
	done []LookupMetrics
	now  func() time.Time // injectable for tests
}

func NewCollector() *Collector {
	return &Collector{aggs: map[uuid.UUID]*lookupAgg{}, now: time.Now}
}

func (c *Collector) process(ev *kaddht.LookupEvent) {
	c.mu.Lock()
	defer c.mu.Unlock()

	a := c.aggs[ev.ID]
	if a == nil {
		a = &lookupAgg{
			start:       c.now(),
			heard:       map[peer.ID]struct{}{},
			queried:     map[peer.ID]struct{}{},
			unreachable: map[peer.ID]struct{}{},
			parent:      map[peer.ID]peer.ID{},
		}
		if ev.Key != nil {
			a.key = hex.EncodeToString([]byte(ev.Key.Key))
		}
		c.aggs[ev.ID] = a
	}

	for _, u := range []*kaddht.LookupUpdateEvent{ev.Request, ev.Response} {
		if u == nil {
			continue
		}
		var src peer.ID
		if u.Source != nil {
			src = u.Source.Peer
		}
		for _, pk := range u.Heard {
			a.heard[pk.Peer] = struct{}{}
			if src != "" {
				if _, ok := a.parent[pk.Peer]; !ok {
					a.parent[pk.Peer] = src
				}
			}
		}
		for _, pk := range u.Waiting {
			a.queried[pk.Peer] = struct{}{}
		}
		for _, pk := range u.Queried {
			a.queried[pk.Peer] = struct{}{}
		}
		for _, pk := range u.Unreachable {
			a.queried[pk.Peer] = struct{}{}
			a.unreachable[pk.Peer] = struct{}{}
		}
	}

	if ev.Terminate != nil {
		a.end = c.now()
		a.terminate = ev.Terminate.Reason.String()
		c.finish(ev.ID, a)
	}
}

func (c *Collector) finish(id uuid.UUID, a *lookupAgg) {
	if a.end.IsZero() {
		a.end = c.now()
	}
	c.done = append(c.done, LookupMetrics{
		ID:           id,
		Key:          a.key,
		LatencyMS:    float64(a.end.Sub(a.start).Microseconds()) / 1000.0,
		PeersHeard:   len(a.heard),
		PeersQueried: len(a.queried),
		Unreachable:  len(a.unreachable),
		Hops:         maxDepth(a.parent),
		Terminate:    a.terminate,
	})
	delete(c.aggs, id)
}

// Completed returns a copy of the metrics collected so far.
func (c *Collector) Completed() []LookupMetrics {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]LookupMetrics, len(c.done))
	copy(out, c.done)
	return out
}

// maxDepth returns the length of the longest chain in the referral tree.
// Seed peers (no recorded parent) sit at depth 0; a peer discovered via a seed
// is at depth 1, and so on. Cycles (should not occur in a referral tree) are
// broken defensively.
func maxDepth(parent map[peer.ID]peer.ID) int {
	memo := map[peer.ID]int{}
	var depth func(p peer.ID, seen map[peer.ID]bool) int
	depth = func(p peer.ID, seen map[peer.ID]bool) int {
		if d, ok := memo[p]; ok {
			return d
		}
		par, ok := parent[p]
		if !ok || seen[p] {
			return 0
		}
		seen[p] = true
		d := depth(par, seen) + 1
		memo[p] = d
		return d
	}
	best := 0
	for p := range parent {
		if d := depth(p, map[peer.ID]bool{}); d > best {
			best = d
		}
	}
	return best
}

func RunInstrumentedLookup(ctx context.Context, d *kaddht.IpfsDHT, key cid.Cid, count int) ([]LookupMetrics, []peer.AddrInfo, error) {
	lctx, cancel := context.WithCancel(ctx)
	regCtx, ch := kaddht.RegisterForLookupEvents(lctx)

	col := NewCollector()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for ev := range ch {
			col.process(ev)
		}
	}()

	var provs []peer.AddrInfo
	for p := range d.FindProvidersAsync(regCtx, key, count) {
		provs = append(provs, p)
	}

	// The providers channel is closed once the lookup finishes; give the
	// Terminate event a brief moment to arrive before we close the stream.
	time.Sleep(50 * time.Millisecond)
	cancel()
	wg.Wait()

	return col.Completed(), provs, nil
}
