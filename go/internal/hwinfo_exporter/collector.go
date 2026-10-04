package main

import (
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

var _ prometheus.Collector = &collector{}

// A collector exposes a Snapshot of HWiNFO's shared memory, read at scrape
// time by the injected function.
type collector struct {
	read func() (*Snapshot, error)
	now  func() time.Time

	up, pollAge, pollingPeriod, sensorInfo, reading *prometheus.Desc
}

// NewCollector creates a prometheus.Collector which reads HWiNFO's shared
// memory through read on each scrape.
func NewCollector(read func() (*Snapshot, error)) prometheus.Collector {
	sensorLabels := []string{"sensor_id", "sensor"}

	return &collector{
		read: read,
		now:  time.Now,

		up: prometheus.NewDesc(
			"hwinfo_up",
			"Whether HWiNFO's shared memory was read and is active.",
			nil, nil,
		),
		pollAge: prometheus.NewDesc(
			"hwinfo_poll_age_seconds",
			"Seconds since HWiNFO last updated its sensor readings.",
			nil, nil,
		),
		pollingPeriod: prometheus.NewDesc(
			"hwinfo_polling_period_seconds",
			"How often HWiNFO updates its sensor readings.",
			nil, nil,
		),
		sensorInfo: prometheus.NewDesc(
			"hwinfo_sensor_info",
			"A sensor HWiNFO reads, always 1.",
			sensorLabels, nil,
		),
		reading: prometheus.NewDesc(
			"hwinfo_sensor_value",
			"A sensor reading as HWiNFO reports it, in the unit its unit label names.",
			append(sensorLabels, "label", "unit", "type"), nil,
		),
	}
}

// Describe implements prometheus.Collector.
func (c *collector) Describe(ch chan<- *prometheus.Desc) {
	ds := []*prometheus.Desc{c.up, c.pollAge, c.pollingPeriod, c.sensorInfo, c.reading}
	for _, d := range ds {
		ch <- d
	}
}

// Collect implements prometheus.Collector.
func (c *collector) Collect(ch chan<- prometheus.Metric) {
	s, err := c.read()
	if err != nil {
		// HWiNFO not running, or sharing switched off, is the expected
		// state while nobody is logged in; anything else is worth a log
		// line.
		if !errors.Is(err, errInactive) && !errors.Is(err, errNotRunning) {
			log.Printf("failed to read HWiNFO shared memory: %v", err)
		}
		ch <- prometheus.MustNewConstMetric(c.up, prometheus.GaugeValue, 0)
		return
	}

	ch <- prometheus.MustNewConstMetric(c.up, prometheus.GaugeValue, 1)
	ch <- prometheus.MustNewConstMetric(c.pollAge, prometheus.GaugeValue, c.now().Sub(s.PollTime).Seconds())
	ch <- prometheus.MustNewConstMetric(c.pollingPeriod, prometheus.GaugeValue, s.PollingPeriod.Seconds())

	ids := make([]string, len(s.Sensors))
	for i, sn := range s.Sensors {
		// ID and instance together identify a sensor; names repeat, such
		// as one per memory module.
		ids[i] = fmt.Sprintf("%08x_%d", sn.ID, sn.Instance)
		ch <- prometheus.MustNewConstMetric(c.sensorInfo, prometheus.GaugeValue, 1, ids[i], sn.Name)
	}

	// A sensor may report two readings under one label; the first wins, so
	// the series set stays unique.
	type key struct{ sensor, label, unit string }
	seen := make(map[key]bool, len(s.Readings))
	for _, r := range s.Readings {
		k := key{ids[r.Sensor], r.Label, r.Unit}
		if seen[k] {
			continue
		}
		seen[k] = true

		ch <- prometheus.MustNewConstMetric(
			c.reading, prometheus.GaugeValue, r.Value,
			ids[r.Sensor], s.Sensors[r.Sensor].Name, r.Label, r.Unit, r.Type.String(),
		)
	}
}
