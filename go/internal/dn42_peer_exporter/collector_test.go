package main

import (
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestCollector(t *testing.T) {
	c := NewCollector(func() []Result {
		return []Result{
			{Peer: "alpha", Up: false},
			{Peer: "bravo", Up: true, RTT: 12500 * time.Microsecond, MTUUp: true},
			{Peer: "charlie", Up: true, RTT: 30 * time.Millisecond},
		}
	})

	const want = `
# HELP dn42_peer_mtu_up Whether the most recent echo request filling the tunnel's MTU to a dn42 peer was answered.
# TYPE dn42_peer_mtu_up gauge
dn42_peer_mtu_up{peer="alpha"} 0
dn42_peer_mtu_up{peer="bravo"} 1
dn42_peer_mtu_up{peer="charlie"} 0
# HELP dn42_peer_rtt_seconds Round trip of the most recent answered echo request to a dn42 peer; absent while the peer is down.
# TYPE dn42_peer_rtt_seconds gauge
dn42_peer_rtt_seconds{peer="bravo"} 0.0125
dn42_peer_rtt_seconds{peer="charlie"} 0.03
# HELP dn42_peer_up Whether the most recent echo request to a dn42 peer's link-local address across its tunnel was answered.
# TYPE dn42_peer_up gauge
dn42_peer_up{peer="alpha"} 0
dn42_peer_up{peer="bravo"} 1
dn42_peer_up{peer="charlie"} 1
`

	if err := testutil.CollectAndCompare(c, strings.NewReader(want)); err != nil {
		t.Fatalf("unexpected metrics: %v", err)
	}
}
