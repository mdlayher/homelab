package main

import (
	"log"
	"slices"
	"sync"

	"github.com/prometheus/client_golang/prometheus"
)

// states are the printer states in PrusaLink's OpenAPI specification.
var states = []string{
	"IDLE", "BUSY", "PRINTING", "PAUSED", "FINISHED",
	"STOPPED", "ERROR", "ATTENTION", "READY",
}

var _ prometheus.Collector = &collector{}

// A collector polls a printer on each scrape.
type collector struct {
	printer func() (*Printer, error)

	// failing records whether the last poll failed, so only a change is
	// logged: the printer is often switched off, and prusa_up carries that.
	mu      sync.Mutex
	failing bool

	up, state, temp, target                *prometheus.Desc
	jobInfo, progress, printing, remaining *prometheus.Desc
}

// NewCollector creates a prometheus.Collector which publishes the printer
// from the input function on each scrape.
func NewCollector(printer func() (*Printer, error)) prometheus.Collector {
	return &collector{
		printer: printer,

		up: prometheus.NewDesc(
			"prusa_up",
			"Whether the printer's PrusaLink API answered the most recent poll.",
			nil, nil,
		),
		state: prometheus.NewDesc(
			"prusa_printer_state",
			"The printer's state, 1 for the current one.",
			[]string{"state"}, nil,
		),
		temp: prometheus.NewDesc(
			"prusa_temperature_celsius",
			"Temperature of a heater.",
			[]string{"heater"}, nil,
		),
		target: prometheus.NewDesc(
			"prusa_temperature_target_celsius",
			"Target temperature of a heater; 0 while it is off.",
			[]string{"heater"}, nil,
		),
		jobInfo: prometheus.NewDesc(
			"prusa_job_info",
			"The current job's file name; absent while there is no job.",
			[]string{"name"}, nil,
		),
		progress: prometheus.NewDesc(
			"prusa_job_progress_ratio",
			"Progress of the current job, from 0 to 1.",
			nil, nil,
		),
		printing: prometheus.NewDesc(
			"prusa_job_printing_seconds",
			"Time the current job has spent printing.",
			nil, nil,
		),
		remaining: prometheus.NewDesc(
			"prusa_job_remaining_seconds",
			"The firmware's estimate of the current job's remaining time; absent while it has none.",
			nil, nil,
		),
	}
}

// Describe implements prometheus.Collector.
func (c *collector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.up
	ch <- c.state
	ch <- c.temp
	ch <- c.target
	ch <- c.jobInfo
	ch <- c.progress
	ch <- c.printing
	ch <- c.remaining
}

// Collect implements prometheus.Collector.
func (c *collector) Collect(ch chan<- prometheus.Metric) {
	p, err := c.printer()
	c.logChange(err)
	if err != nil {
		ch <- prometheus.MustNewConstMetric(c.up, prometheus.GaugeValue, 0)
		return
	}
	ch <- prometheus.MustNewConstMetric(c.up, prometheus.GaugeValue, 1)

	// Every known state is published so a state change is a value change
	// rather than a new series; one the specification lacks is added.
	for _, s := range states {
		ch <- prometheus.MustNewConstMetric(c.state, prometheus.GaugeValue, boolFloat(s == p.State), s)
	}
	if !slices.Contains(states, p.State) {
		ch <- prometheus.MustNewConstMetric(c.state, prometheus.GaugeValue, 1, p.State)
	}

	ch <- prometheus.MustNewConstMetric(c.temp, prometheus.GaugeValue, p.NozzleTemp, "nozzle")
	ch <- prometheus.MustNewConstMetric(c.target, prometheus.GaugeValue, p.NozzleTarget, "nozzle")
	ch <- prometheus.MustNewConstMetric(c.temp, prometheus.GaugeValue, p.BedTemp, "bed")
	ch <- prometheus.MustNewConstMetric(c.target, prometheus.GaugeValue, p.BedTarget, "bed")

	j := p.Job
	if j == nil {
		return
	}
	ch <- prometheus.MustNewConstMetric(c.jobInfo, prometheus.GaugeValue, 1, j.Name)
	ch <- prometheus.MustNewConstMetric(c.progress, prometheus.GaugeValue, j.Progress)
	ch <- prometheus.MustNewConstMetric(c.printing, prometheus.GaugeValue, j.Printing.Seconds())
	if j.Remaining >= 0 {
		ch <- prometheus.MustNewConstMetric(c.remaining, prometheus.GaugeValue, j.Remaining.Seconds())
	}
}

// logChange logs a poll's outcome when it differs from the last one.
func (c *collector) logChange(err error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	switch {
	case err != nil && !c.failing:
		log.Printf("failed to poll printer: %v", err)
	case err == nil && c.failing:
		log.Print("polled printer")
	}
	c.failing = err != nil
}

func boolFloat(b bool) float64 {
	if b {
		return 1
	}
	return 0
}
