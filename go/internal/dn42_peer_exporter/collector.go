package main

import (
	"github.com/prometheus/client_golang/prometheus"
)

var _ prometheus.Collector = &collector{}

// A collector publishes the latest probe result for each peer. Results are
// read from the injected function at scrape time, so a scrape never waits
// on a probe.
type collector struct {
	results func() []Result

	up, rtt, mtuUp *prometheus.Desc
}

// NewCollector creates a prometheus.Collector which publishes the probe
// results from the input function on each scrape.
func NewCollector(results func() []Result) prometheus.Collector {
	labels := []string{"peer"}

	return &collector{
		results: results,

		up: prometheus.NewDesc(
			"dn42_peer_up",
			"Whether the most recent echo request to a dn42 peer's link-local address across its tunnel was answered.",
			labels, nil,
		),
		rtt: prometheus.NewDesc(
			"dn42_peer_rtt_seconds",
			"Round trip of the most recent answered echo request to a dn42 peer; absent while the peer is down.",
			labels, nil,
		),
		mtuUp: prometheus.NewDesc(
			"dn42_peer_mtu_up",
			"Whether the most recent echo request filling the tunnel's MTU to a dn42 peer was answered.",
			labels, nil,
		),
	}
}

// Describe implements prometheus.Collector.
func (c *collector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.up
	ch <- c.rtt
	ch <- c.mtuUp
}

// Collect implements prometheus.Collector.
func (c *collector) Collect(ch chan<- prometheus.Metric) {
	for _, r := range c.results() {
		ch <- prometheus.MustNewConstMetric(c.up, prometheus.GaugeValue, boolFloat(r.Up), r.Peer)
		ch <- prometheus.MustNewConstMetric(c.mtuUp, prometheus.GaugeValue, boolFloat(r.MTUUp), r.Peer)

		// A failed probe has no round trip; publishing zero would read as
		// a fast peer and drag down any average.
		if r.Up {
			ch <- prometheus.MustNewConstMetric(c.rtt, prometheus.GaugeValue, r.RTT.Seconds(), r.Peer)
		}
	}
}

func boolFloat(b bool) float64 {
	if b {
		return 1
	}
	return 0
}
