package main

import (
	"context"
	"encoding/csv"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/ipfs/go-cid"
	libp2p "github.com/libp2p/go-libp2p"
	kaddht "github.com/libp2p/go-libp2p-kad-dht"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/core/pnet"
	"github.com/libp2p/go-libp2p/core/protocol"
	ma "github.com/multiformats/go-multiaddr"
)

func envInt(name string, def int) int {
	if v := os.Getenv(name); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return def
}

func envStr(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func main() {
	var (
		bootstrap = flag.String("bootstrap", "", "comma-separated bootstrap multiaddrs (/ip4/.../p2p/<id>)")
		cidStr    = flag.String("cid", "", "CID to look up (required)")
		count     = flag.Int("count", 1, "number of provider records to seek per lookup")
		alpha     = flag.Int("alpha", envInt("EXP_DHT_ALPHA", 10), "Kademlia query concurrency (alpha)")
		k         = flag.Int("k", envInt("EXP_DHT_BUCKET_K", 20), "Kademlia bucket size (K)")
		trials    = flag.Int("trials", 1, "number of lookups to run")
		swarmKey  = flag.String("swarmkey", "", "path to a pnet swarm.key (enables private network)")
		privNet   = flag.Bool("privatenet", false, "accept private-IP peers into queries + routing table (required on a container/private testbed)")
		protoPfx  = flag.String("protocol-prefix", envStr("EXP_DHT_PROTOCOL_PREFIX", "/exp"), "custom DHT protocol prefix; MUST match the nodes under test (they run /exp/kad/1.0.0 in private-net mode). Only applied with -privatenet. A non-\"/ipfs\" prefix is also what makes K != 20 legal (kad-dht Validate() enforces K==20 only on the Amino default prefix).")
		outPath   = flag.String("out", "", "CSV output path (default: stdout)")
		timeout   = flag.Duration("timeout", 60*time.Second, "overall timeout")
		settle    = flag.Duration("settle", 5*time.Second, "wait after bootstrap for routing tables to fill")
		appendOut = flag.Bool("append", false, "append to -out instead of truncating it (skips the header if the file already has content); needed when a fleet driver invokes this binary once per trial against the same long-lived node, since a fresh -out each time would discard every prior trial's row")
		trialFrom = flag.Int("trial-start", 1, "trial number to label the first row with (use with -append + -trials 1 so each invocation's row gets its own global trial index instead of always being row 1)")
	)
	flag.Parse()

	if *cidStr == "" {
		fmt.Fprintln(os.Stderr, "error: -cid is required")
		flag.Usage()
		os.Exit(2)
	}
	target, err := cid.Decode(*cidStr)
	if err != nil {
		fatalf("bad -cid %q: %v", *cidStr, err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	// libp2p host, optionally walled into a private network.
	hostOpts := []libp2p.Option{libp2p.ListenAddrStrings("/ip4/0.0.0.0/tcp/0")}
	if *swarmKey != "" {
		f, err := os.Open(*swarmKey)
		if err != nil {
			fatalf("open swarmkey: %v", err)
		}
		psk, err := pnet.DecodeV1PSK(f)
		f.Close()
		if err != nil {
			fatalf("decode swarmkey: %v", err)
		}
		hostOpts = append(hostOpts, libp2p.PrivateNetwork(psk))
	}
	h, err := libp2p.New(hostOpts...)
	if err != nil {
		fatalf("libp2p.New: %v", err)
	}
	defer h.Close()

	dhtOpts := []kaddht.Option{
		kaddht.Mode(kaddht.ModeServer),
		kaddht.Concurrency(*alpha),
		kaddht.BucketSize(*k),
	}
	if *privNet {
		// On a private/container testbed every peer sits on a private IP. The
		// default public filters would refuse those peers, leaving the routing
		// table empty. The private filters accept them. This mirrors the
		// EXP_DHT_PRIVATE_NET switch added to the Kubo nodes under test.
		dhtOpts = append(dhtOpts,
			kaddht.QueryFilter(kaddht.PrivateQueryFilter),
			kaddht.RoutingTableFilter(kaddht.PrivateRoutingTableFilter),
		)
		dhtOpts = append(dhtOpts, kaddht.ProtocolPrefix(protocol.ID(*protoPfx)))
	}
	d, err := kaddht.New(h, dhtOpts...)
	if err != nil {
		fatalf("kaddht.New: %v", err)
	}
	defer d.Close()

	if err := connectBootstrap(ctx, h, *bootstrap); err != nil {
		fatalf("%v", err)
	}
	if err := d.Bootstrap(ctx); err != nil {
		fatalf("dht bootstrap: %v", err)
	}
	fmt.Fprintf(os.Stderr, "node %s up (alpha=%d k=%d); settling %s...\n", h.ID(), *alpha, *k, *settle)
	time.Sleep(*settle)

	var w *csv.Writer
	writeHeader := true
	switch {
	case *outPath == "" || *outPath == "-":
		w = csv.NewWriter(os.Stdout)
	case *appendOut:
		f, err := os.OpenFile(*outPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			fatalf("open out (append): %v", err)
		}
		defer f.Close()
		if info, statErr := f.Stat(); statErr == nil && info.Size() > 0 {
			writeHeader = false
		}
		w = csv.NewWriter(f)
	default:
		f, err := os.Create(*outPath)
		if err != nil {
			fatalf("create out: %v", err)
		}
		defer f.Close()
		w = csv.NewWriter(f)
	}
	defer w.Flush()
	if writeHeader {
		_ = w.Write([]string{
			"trial", "lookup_id", "key", "latency_ms", "peers_heard",
			"peers_queried", "unreachable", "hops", "terminate", "alpha", "k",
			"providers", "success",
		})
	}

	for t := *trialFrom; t < *trialFrom+*trials; t++ {
		mets, provs, err := RunInstrumentedLookup(ctx, d, target, *count)
		if err != nil {
			fatalf("trial %d: %v", t, err)
		}
		success := len(provs) > 0
		if len(mets) == 0 {
			// Lookup produced no event (should not happen once registered);
			// still emit a row so the run is auditable.
			_ = w.Write([]string{
				strconv.Itoa(t), "", target.String(), "", "", "", "", "", "no-event",
				strconv.Itoa(*alpha), strconv.Itoa(*k), strconv.Itoa(len(provs)), strconv.FormatBool(success),
			})
			continue
		}
		for _, m := range mets {
			_ = w.Write([]string{
				strconv.Itoa(t),
				m.ID.String(),
				m.Key,
				strconv.FormatFloat(m.LatencyMS, 'f', 3, 64),
				strconv.Itoa(m.PeersHeard),
				strconv.Itoa(m.PeersQueried),
				strconv.Itoa(m.Unreachable),
				strconv.Itoa(m.Hops),
				m.Terminate,
				strconv.Itoa(*alpha),
				strconv.Itoa(*k),
				strconv.Itoa(len(provs)),
				strconv.FormatBool(success),
			})
		}
		w.Flush()
	}
	fmt.Fprintln(os.Stderr, "done")
}

func connectBootstrap(ctx context.Context, h interface {
	Connect(context.Context, peer.AddrInfo) error
}, list string) error {
	list = strings.TrimSpace(list)
	if list == "" {
		return nil
	}
	var connected int
	for _, s := range strings.Split(list, ",") {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		maddr, err := ma.NewMultiaddr(s)
		if err != nil {
			return fmt.Errorf("bad bootstrap addr %q: %w", s, err)
		}
		ai, err := peer.AddrInfoFromP2pAddr(maddr)
		if err != nil {
			return fmt.Errorf("bad bootstrap addr %q: %w", s, err)
		}
		if err := h.Connect(ctx, *ai); err != nil {
			fmt.Fprintf(os.Stderr, "warn: connect %s: %v\n", ai.ID, err)
			continue
		}
		connected++
	}
	if connected == 0 {
		return fmt.Errorf("no bootstrap peers reachable")
	}
	return nil
}

func fatalf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", a...)
	os.Exit(1)
}
