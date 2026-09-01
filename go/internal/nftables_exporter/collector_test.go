package main

import (
	"errors"
	"strings"
	"testing"

	"github.com/google/nftables"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestCollector(t *testing.T) {
	c := NewCollector(func() (*Stats, error) {
		return &Stats{
			Counters: []Counter{
				{
					Family:  "inet",
					Table:   "accounting",
					Name:    "lan0_wan_out",
					Bytes:   1024,
					Packets: 10,
				},
				{
					Family:  "inet",
					Table:   "filter",
					Name:    "spoofed_drop",
					Bytes:   64,
					Packets: 1,
				},
			},
			SetCounters: []SetCounter{
				{
					Family:  "inet",
					Table:   "accounting",
					Set:     "host4_wan_out",
					Element: "192.0.2.10",
					Bytes:   2048,
					Packets: 20,
				},
				{
					Family:  "inet",
					Table:   "accounting",
					Set:     "host6_wan_out",
					Element: "2001:db8::10",
					Bytes:   4096,
					Packets: 40,
				},
			},
		}, nil
	})

	const want = `
# HELP nftables_counter_bytes_total Number of bytes matched by a named nftables counter.
# TYPE nftables_counter_bytes_total counter
nftables_counter_bytes_total{family="inet",name="lan0_wan_out",table="accounting"} 1024
nftables_counter_bytes_total{family="inet",name="spoofed_drop",table="filter"} 64
# HELP nftables_counter_packets_total Number of packets matched by a named nftables counter.
# TYPE nftables_counter_packets_total counter
nftables_counter_packets_total{family="inet",name="lan0_wan_out",table="accounting"} 10
nftables_counter_packets_total{family="inet",name="spoofed_drop",table="filter"} 1
# HELP nftables_set_element_bytes_total Number of bytes matched by an nftables set element counter.
# TYPE nftables_set_element_bytes_total counter
nftables_set_element_bytes_total{element="192.0.2.10",family="inet",set="host4_wan_out",table="accounting"} 2048
nftables_set_element_bytes_total{element="2001:db8::10",family="inet",set="host6_wan_out",table="accounting"} 4096
# HELP nftables_set_element_packets_total Number of packets matched by an nftables set element counter.
# TYPE nftables_set_element_packets_total counter
nftables_set_element_packets_total{element="192.0.2.10",family="inet",set="host4_wan_out",table="accounting"} 20
nftables_set_element_packets_total{element="2001:db8::10",family="inet",set="host6_wan_out",table="accounting"} 40
`

	if err := testutil.CollectAndCompare(c, strings.NewReader(want)); err != nil {
		t.Fatalf("unexpected metrics output: %v", err)
	}
}

func TestCollectorError(t *testing.T) {
	c := NewCollector(func() (*Stats, error) {
		return nil, errors.New("some error")
	})

	// An error fetching statistics must surface as a scrape failure rather
	// than an empty, healthy-looking result.
	reg := prometheus.NewPedanticRegistry()
	reg.MustRegister(c)

	if _, err := reg.Gather(); err == nil {
		t.Fatal("expected a gather error, but none occurred")
	}
}

func TestElementString(t *testing.T) {
	// An interface name padded to nftables' fixed 16 byte ifname size.
	ifname := func(s string) []byte {
		b := make([]byte, 16)
		copy(b, s)
		return b
	}

	ip6 := []byte{
		0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0x10,
	}

	tests := []struct {
		name string
		kt   nftables.SetDatatype
		key  []byte
		want string
	}{
		{
			name: "IPv4",
			kt:   nftables.TypeIPAddr,
			key:  []byte{192, 0, 2, 10},
			want: "192.0.2.10",
		},
		{
			name: "IPv6",
			kt:   nftables.TypeIP6Addr,
			key:  ip6,
			want: "2001:db8::10",
		},
		{
			name: "unknown type",
			kt:   nftables.TypeInvalid,
			key:  []byte{0xde, 0xad},
			want: "dead",
		},
		{
			name: "ifname and IPv4",
			kt:   nftables.MustConcatSetType(nftables.TypeIFName, nftables.TypeIPAddr),
			key:  append(ifname("lan0"), 192, 0, 2, 10),
			want: "lan0 . 192.0.2.10",
		},
		{
			name: "ifname and IPv6",
			kt:   nftables.MustConcatSetType(nftables.TypeIFName, nftables.TypeIP6Addr),
			key:  append(ifname("iot0"), ip6...),
			want: "iot0 . 2001:db8::10",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := elementString(tt.kt, tt.key); got != tt.want {
				t.Fatalf("unexpected element string: got %q, want %q", got, tt.want)
			}
		})
	}
}
