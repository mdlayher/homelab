// Command nftables_exporter implements a Prometheus exporter for nftables
// named counter objects.
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func main() {
	var (
		metricsAddr = flag.String("metrics.addr", ":9630", "address for nftables exporter")
		metricsPath = flag.String("metrics.path", "/metrics", "URL path for surfacing metrics")
	)
	flag.Parse()

	reg := prometheus.NewPedanticRegistry()
	reg.MustRegister(NewCollector(fetchStats))

	mux := http.NewServeMux()
	mux.Handle(*metricsPath, promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprintf(w, "nftables_exporter: %s\n", *metricsPath)
	})

	log.Printf("starting nftables exporter on %q", *metricsAddr)

	if err := http.ListenAndServe(*metricsAddr, mux); err != nil {
		log.Fatalf("cannot start nftables exporter: %v", err)
	}
}
