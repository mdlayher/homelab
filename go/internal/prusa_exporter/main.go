// Command prusa_exporter implements a Prometheus exporter for a Prusa
// printer's state, temperatures, and current job, polled from its PrusaLink
// API on each scrape.
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func main() {
	var (
		metricsAddr = flag.String("metrics.addr", ":9632", "address for Prusa exporter")
		metricsPath = flag.String("metrics.path", "/metrics", "URL path for surfacing metrics")
		printerAddr = flag.String("printer.addr", "", "host and optional port of the printer's PrusaLink API")
		timeout     = flag.Duration("printer.timeout", 5*time.Second, "time allowed for each PrusaLink request")
	)
	flag.Parse()

	if *printerAddr == "" {
		log.Fatal("-printer.addr is required")
	}
	// The PrusaLink password set on the printer.
	apiKey := os.Getenv("PRUSALINK_API_KEY")
	if apiKey == "" {
		log.Fatal("PRUSALINK_API_KEY is required")
	}

	c := NewClient(*printerAddr, apiKey, *timeout)

	reg := prometheus.NewPedanticRegistry()
	reg.MustRegister(NewCollector(c.Printer))

	mux := http.NewServeMux()
	mux.Handle(*metricsPath, promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprintf(w, "prusa_exporter: %s\n", *metricsPath)
	})

	log.Printf("starting Prusa exporter on %q for printer %q", *metricsAddr, *printerAddr)

	if err := http.ListenAndServe(*metricsAddr, mux); err != nil {
		log.Fatalf("cannot start Prusa exporter: %v", err)
	}
}
