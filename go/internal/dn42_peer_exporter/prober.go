package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/mdlayher/icmpx"
	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv6"
)

// A Peer is a dn42 peer, reached at a link-local address whose zone names
// the tunnel interface the address lives on.
type Peer struct {
	Name string
	Addr netip.Addr
}

// ParsePeer parses a peer in the form name=link-local%interface.
func ParsePeer(s string) (Peer, error) {
	name, addr, ok := strings.Cut(s, "=")
	if !ok || name == "" {
		return Peer{}, fmt.Errorf("peer %q must be name=link-local%%interface", s)
	}

	ip, err := netip.ParseAddr(addr)
	if err != nil {
		return Peer{}, fmt.Errorf("peer %q: %v", name, err)
	}
	if !ip.Is6() || !ip.IsLinkLocalUnicast() {
		return Peer{}, fmt.Errorf("peer %q: %s is not an IPv6 link-local address", name, ip)
	}
	if ip.Zone() == "" {
		return Peer{}, fmt.Errorf("peer %q: %s names no interface as its zone", name, ip)
	}

	return Peer{Name: name, Addr: ip}, nil
}

// peerFlags collects repeated -peer flags.
type peerFlags []Peer

func (p *peerFlags) String() string {
	ss := make([]string, 0, len(*p))
	for _, peer := range *p {
		ss = append(ss, peer.Name+"="+peer.Addr.String())
	}
	return strings.Join(ss, ",")
}

func (p *peerFlags) Set(s string) error {
	peer, err := ParsePeer(s)
	if err != nil {
		return err
	}
	for _, have := range *p {
		if have.Name == peer.Name {
			return fmt.Errorf("peer %q is declared twice", peer.Name)
		}
	}

	*p = append(*p, peer)
	return nil
}

// A Result is the outcome of the most recent probe of a peer. RTT is only
// meaningful when Up is true, and MTUUp reports whether an echo request
// filling the tunnel's MTU was answered as well.
type Result struct {
	Peer  string
	Up    bool
	RTT   time.Duration
	MTUUp bool
}

// A ProbeFunc probes one peer. A non-nil error explains why the peer is
// down.
type ProbeFunc func(ctx context.Context, peer Peer, seq int) (Result, error)

// A Prober probes every peer at a fixed interval in the background and keeps
// the latest result for each.
type Prober struct {
	peers   []Peer
	timeout time.Duration
	probe   ProbeFunc

	mu      sync.Mutex
	seq     int
	results map[string]Result
}

// NewProber creates a Prober which probes the peers with probe, allowing
// each peer timeout per pass. Results are empty until Run completes a pass.
func NewProber(peers []Peer, timeout time.Duration, probe ProbeFunc) *Prober {
	return &Prober{
		peers:   peers,
		timeout: timeout,
		probe:   probe,
		results: make(map[string]Result, len(peers)),
	}
}

// Run probes every peer immediately and then once per interval until ctx is
// canceled.
func (p *Prober) Run(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()

	for {
		p.Probe(ctx)

		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Probe probes every peer once, concurrently, and records the results.
func (p *Prober) Probe(ctx context.Context) {
	p.mu.Lock()
	p.seq = (p.seq + 1) & 0xffff
	seq := p.seq
	p.mu.Unlock()

	var wg sync.WaitGroup
	for _, peer := range p.peers {
		wg.Add(1)
		go func() {
			defer wg.Done()

			ctx, cancel := context.WithTimeout(ctx, p.timeout)
			defer cancel()

			res, err := p.probe(ctx, peer, seq)
			res.Peer = peer.Name

			p.mu.Lock()
			prev, seen := p.results[peer.Name]
			p.results[peer.Name] = res
			p.mu.Unlock()

			// Log transitions only, so a peer that stays down is quiet.
			switch {
			case !res.Up && (!seen || prev.Up):
				log.Printf("peer %q down: %v", peer.Name, err)
			case res.Up && seen && !prev.Up:
				log.Printf("peer %q up: %s round trip", peer.Name, res.RTT)
			}
			if res.Up && seen && prev.Up && res.MTUUp != prev.MTUUp {
				if res.MTUUp {
					log.Printf("peer %q answers full-size echo again", peer.Name)
				} else {
					log.Printf("peer %q answers but drops full-size echo", peer.Name)
				}
			}
		}()
	}
	wg.Wait()
}

// Results returns the latest result for each probed peer, sorted by name.
func (p *Prober) Results() []Result {
	p.mu.Lock()
	defer p.mu.Unlock()

	rs := make([]Result, 0, len(p.results))
	for _, r := range p.results {
		rs = append(rs, r)
	}
	sort.Slice(rs, func(i, j int) bool { return rs[i].Peer < rs[j].Peer })

	return rs
}

// echoID identifies this process's echo requests among any others on a link.
var echoID = os.Getpid() & 0xffff

// IPv6 and ICMPv6 header lengths, which a full-size echo request leaves
// room for within the tunnel's MTU.
const (
	ipv6HeaderLen = 40
	icmpHeaderLen = 8
)

// probe sends ICMPv6 echo requests to a peer over a raw socket bound to the
// peer's tunnel interface: one empty, for the round trip, and then one
// filling the tunnel's MTU, which its reply mirrors, so a path dropping
// full-size packets in either direction shows as MTUUp false while the peer
// is up. Opening the socket per probe means a tunnel recreated since the
// last probe is picked up by name, and any interface or address error
// surfaces as a failed probe rather than a stale socket.
func probe(ctx context.Context, peer Peer, seq int) (Result, error) {
	ifi, err := net.InterfaceByName(peer.Addr.Zone())
	if err != nil {
		return Result{}, err
	}

	c, err := icmpx.ListenIPv6(ifi, icmpx.IPv6Config{
		Filter: icmpx.IPv6AllowOnly(ipv6.ICMPTypeEchoReply),
	})
	if err != nil {
		return Result{}, err
	}
	defer c.Close()

	rtt, err := echo(ctx, c, peer.Addr, seq, 0)
	if err != nil {
		return Result{}, err
	}

	_, err = echo(ctx, c, peer.Addr, seq, max(ifi.MTU-ipv6HeaderLen-icmpHeaderLen, 0))
	return Result{Up: true, RTT: rtt, MTUUp: err == nil}, nil
}

// echo sends one echo request carrying size bytes of payload and waits for
// the matching reply, reporting the round trip.
func echo(ctx context.Context, c *icmpx.IPv6Conn, dst netip.Addr, seq, size int) (time.Duration, error) {
	req := icmp.Message{
		Type: ipv6.ICMPTypeEchoRequest,
		Body: &icmp.Echo{ID: echoID, Seq: seq, Data: make([]byte, size)},
	}

	start := time.Now()
	if err := c.WriteTo(ctx, &req, dst); err != nil {
		return 0, err
	}

	for {
		m, from, err := c.ReadFrom(ctx)
		if err != nil {
			return 0, err
		}

		// Only our own reply to this request from this peer counts; the
		// payload length tells the two requests of a probe apart, and the
		// reply's zone is the interface name, as in the peer's address.
		echo, ok := m.Body.(*icmp.Echo)
		if !ok || echo.ID != echoID || echo.Seq != seq || len(echo.Data) != size || from != dst {
			continue
		}

		return time.Since(start), nil
	}
}
