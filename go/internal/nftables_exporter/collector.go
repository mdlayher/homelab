package main

import (
	"github.com/prometheus/client_golang/prometheus"
)

// A Counter is a named nftables counter object.
type Counter struct {
	Family  string
	Table   string
	Name    string
	Bytes   uint64
	Packets uint64
}

// A SetCounter is a per-element counter from an nftables set whose elements
// carry counters, such as a dynamic set which learns hosts from traffic.
type SetCounter struct {
	Family  string
	Table   string
	Set     string
	Element string
	Bytes   uint64
	Packets uint64
}

// Stats carries every nftables statistic gathered in one pass.
type Stats struct {
	Counters    []Counter
	SetCounters []SetCounter
}

var _ prometheus.Collector = &collector{}

// A collector gathers nftables statistics for Prometheus. Statistics are
// fetched at scrape time by the injected function.
type collector struct {
	stats func() (*Stats, error)

	bytes, packets       *prometheus.Desc
	setBytes, setPackets *prometheus.Desc
}

// NewCollector creates a prometheus.Collector which gathers nftables
// statistics from the input function on each scrape.
func NewCollector(stats func() (*Stats, error)) prometheus.Collector {
	var (
		counterLabels = []string{"family", "table", "name"}
		setLabels     = []string{"family", "table", "set", "element"}
	)

	return &collector{
		stats: stats,

		bytes: prometheus.NewDesc(
			"nftables_counter_bytes_total",
			"Number of bytes matched by a named nftables counter.",
			counterLabels, nil,
		),
		packets: prometheus.NewDesc(
			"nftables_counter_packets_total",
			"Number of packets matched by a named nftables counter.",
			counterLabels, nil,
		),
		setBytes: prometheus.NewDesc(
			"nftables_set_element_bytes_total",
			"Number of bytes matched by an nftables set element counter.",
			setLabels, nil,
		),
		setPackets: prometheus.NewDesc(
			"nftables_set_element_packets_total",
			"Number of packets matched by an nftables set element counter.",
			setLabels, nil,
		),
	}
}

// Describe implements prometheus.Collector.
func (c *collector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.bytes
	ch <- c.packets
	ch <- c.setBytes
	ch <- c.setPackets
}

// Collect implements prometheus.Collector.
func (c *collector) Collect(ch chan<- prometheus.Metric) {
	stats, err := c.stats()
	if err != nil {
		ch <- prometheus.NewInvalidMetric(c.bytes, err)
		return
	}

	for _, cnt := range stats.Counters {
		ch <- prometheus.MustNewConstMetric(
			c.bytes, prometheus.CounterValue,
			float64(cnt.Bytes),
			cnt.Family, cnt.Table, cnt.Name,
		)
		ch <- prometheus.MustNewConstMetric(
			c.packets, prometheus.CounterValue,
			float64(cnt.Packets),
			cnt.Family, cnt.Table, cnt.Name,
		)
	}

	for _, sc := range stats.SetCounters {
		ch <- prometheus.MustNewConstMetric(
			c.setBytes, prometheus.CounterValue,
			float64(sc.Bytes),
			sc.Family, sc.Table, sc.Set, sc.Element,
		)
		ch <- prometheus.MustNewConstMetric(
			c.setPackets, prometheus.CounterValue,
			float64(sc.Packets),
			sc.Family, sc.Table, sc.Set, sc.Element,
		)
	}
}
