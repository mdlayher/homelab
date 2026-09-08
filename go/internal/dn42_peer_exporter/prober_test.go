package main

import (
	"context"
	"errors"
	"net/netip"
	"reflect"
	"testing"
	"time"
)

func TestParsePeer(t *testing.T) {
	tests := []struct {
		s    string
		want Peer
		ok   bool
	}{
		{s: "alpha=fe80::1%dn42e-alpha", want: Peer{Name: "alpha", Addr: netip.MustParseAddr("fe80::1%dn42e-alpha")}, ok: true},
		// Missing name, address, or zone.
		{s: "fe80::1%dn42e-alpha"},
		{s: "=fe80::1%dn42e-alpha"},
		{s: "alpha=fe80::1"},
		// Not link-local.
		{s: "alpha=fd42::1%dn42e-alpha"},
		{s: "alpha=192.0.2.1%dn42e-alpha"},
	}

	for _, tt := range tests {
		t.Run(tt.s, func(t *testing.T) {
			got, err := ParsePeer(tt.s)
			if (err == nil) != tt.ok {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Fatalf("unexpected peer:\n got: %+v\nwant: %+v", got, tt.want)
			}
		})
	}
}

func TestProberProbe(t *testing.T) {
	peers := []Peer{
		{Name: "alpha", Addr: netip.MustParseAddr("fe80::1%dn42e-alpha")},
		{Name: "bravo", Addr: netip.MustParseAddr("fe80::2%dn42e-bravo")},
	}

	p := NewProber(peers, time.Second, func(_ context.Context, peer Peer, seq int) (Result, error) {
		if seq != 1 {
			t.Errorf("unexpected sequence %d for %q", seq, peer.Name)
		}
		if peer.Name == "alpha" {
			return Result{}, errors.New("no reply")
		}
		return Result{Up: true, RTT: 20 * time.Millisecond, MTUUp: true}, nil
	})

	if got := p.Results(); len(got) != 0 {
		t.Fatalf("results before any probe: %+v", got)
	}

	p.Probe(context.Background())

	want := []Result{
		{Peer: "alpha", Up: false},
		{Peer: "bravo", Up: true, RTT: 20 * time.Millisecond, MTUUp: true},
	}
	if got := p.Results(); !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected results:\n got: %+v\nwant: %+v", got, want)
	}
}
