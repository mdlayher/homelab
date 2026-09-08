// Command dn42_peer_exporter implements a Prometheus exporter for the round
// trip to each dn42 peer's link-local address across its tunnel interface.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func main() {
	var (
		metricsAddr = flag.String("metrics.addr", ":9631", "address for dn42 peer exporter")
		metricsPath = flag.String("metrics.path", "/metrics", "URL path for surfacing metrics")
		interval    = flag.Duration("probe.interval", 15*time.Second, "time between probes of every peer")
		timeout     = flag.Duration("probe.timeout", 5*time.Second, "time allowed for a peer's echo replies")

		peers peerFlags
	)
	flag.Var(&peers, "peer", "peer to probe as name=link-local%interface (repeatable)")
	flag.Parse()

	if len(peers) == 0 {
		log.Fatal("at least one -peer is required")
	}
	if *timeout >= *interval {
		log.Fatalf("probe timeout %s must be shorter than probe interval %s", *timeout, *interval)
	}

	p := NewProber(peers, *timeout, probe)
	go p.Run(context.Background(), *interval)

	reg := prometheus.NewPedanticRegistry()
	reg.MustRegister(NewCollector(p.Results))

	mux := http.NewServeMux()
	mux.Handle(*metricsPath, promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprintf(w, "dn42_peer_exporter: %s\n", *metricsPath)
	})

	log.Printf("starting dn42 peer exporter on %q, probing %d peers every %s", *metricsAddr, len(peers), *interval)

	if err := http.ListenAndServe(*metricsAddr, mux); err != nil {
		log.Fatalf("cannot start dn42 peer exporter: %v", err)
	}
}
