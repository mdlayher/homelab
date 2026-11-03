package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

const (
	headerState = `
# HELP prusa_printer_state The printer's state, 1 for the current one.
# TYPE prusa_printer_state gauge
`
	headerTemps = `
# HELP prusa_temperature_celsius Temperature of a heater.
# TYPE prusa_temperature_celsius gauge
`
	headerTargets = `
# HELP prusa_temperature_target_celsius Target temperature of a heater; 0 while it is off.
# TYPE prusa_temperature_target_celsius gauge
`
	headerUp = `
# HELP prusa_up Whether the printer's PrusaLink API answered the most recent poll.
# TYPE prusa_up gauge
`
)

func TestCollectorPrinting(t *testing.T) {
	c := testCollector(t, "testdata/status.json", "testdata/job.json")

	want := `
# HELP prusa_job_info The current job's file name; absent while there is no job.
# TYPE prusa_job_info gauge
prusa_job_info{name="benchy_0.4n_0.2mm_PLA_COREONE_43m.bgcode"} 1
# HELP prusa_job_printing_seconds Time the current job has spent printing.
# TYPE prusa_job_printing_seconds gauge
prusa_job_printing_seconds 2940
# HELP prusa_job_progress_ratio Progress of the current job, from 0 to 1.
# TYPE prusa_job_progress_ratio gauge
prusa_job_progress_ratio 0.37
# HELP prusa_job_remaining_seconds The firmware's estimate of the current job's remaining time; absent while it has none.
# TYPE prusa_job_remaining_seconds gauge
prusa_job_remaining_seconds 4980
` + headerState + states1("PRINTING") + headerTemps + `
prusa_temperature_celsius{heater="bed"} 59.9
prusa_temperature_celsius{heater="nozzle"} 214.8
` + headerTargets + `
prusa_temperature_target_celsius{heater="bed"} 60
prusa_temperature_target_celsius{heater="nozzle"} 215
` + headerUp + `
prusa_up 1
`

	if err := testutil.CollectAndCompare(c, strings.NewReader(want)); err != nil {
		t.Fatalf("unexpected metrics: %v", err)
	}
}

func TestCollectorIdle(t *testing.T) {
	c := testCollector(t, "testdata/status-idle.json", "")

	want := headerState + states1("IDLE") + headerTemps + `
prusa_temperature_celsius{heater="bed"} 21.4
prusa_temperature_celsius{heater="nozzle"} 22.1
` + headerTargets + `
prusa_temperature_target_celsius{heater="bed"} 0
prusa_temperature_target_celsius{heater="nozzle"} 0
` + headerUp + `
prusa_up 1
`

	if err := testutil.CollectAndCompare(c, strings.NewReader(want)); err != nil {
		t.Fatalf("unexpected metrics: %v", err)
	}
}

func TestCollectorUnauthorized(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(srv.Close)

	c := NewCollector(NewClient(strings.TrimPrefix(srv.URL, "http://"), "key", time.Second).Printer)

	if err := testutil.CollectAndCompare(c, strings.NewReader(headerUp+"prusa_up 0\n")); err != nil {
		t.Fatalf("unexpected metrics: %v", err)
	}
}

// testCollector serves the status and job files as PrusaLink would, the
// job as 204 No Content when its file is empty, and requires the API key.
func testCollector(t *testing.T, status, job string) *collector {
	t.Helper()

	const key = "secret"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Api-Key") != key {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}

		var file string
		switch r.URL.Path {
		case "/api/v1/status":
			file = status
		case "/api/v1/job":
			if job == "" {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			file = job
		default:
			w.WriteHeader(http.StatusNotFound)
			return
		}

		b, err := os.ReadFile(file)
		if err != nil {
			panic(err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(b)
	}))
	t.Cleanup(srv.Close)

	client := NewClient(strings.TrimPrefix(srv.URL, "http://"), key, time.Second)
	return NewCollector(client.Printer).(*collector)
}

// states1 renders prusa_printer_state with current set to 1.
func states1(current string) string {
	var b strings.Builder
	for _, s := range states {
		v := "0"
		if s == current {
			v = "1"
		}
		b.WriteString(`prusa_printer_state{state="` + s + `"} ` + v + "\n")
	}
	return b.String()
}
