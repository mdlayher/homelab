// Command hwinfo_exporter implements a Prometheus exporter for the sensor
// readings HWiNFO shares through its shared memory interface on Windows.
package main

import (
	"flag"
	"fmt"
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func main() {
	var (
		metricsAddr = flag.String("metrics.addr", ":9888", "address for HWiNFO exporter")
		metricsPath = flag.String("metrics.path", "/metrics", "URL path for surfacing metrics")
	)
	flag.Parse()

	reg := prometheus.NewPedanticRegistry()
	reg.MustRegister(NewCollector(readShared))

	mux := http.NewServeMux()
	mux.Handle(*metricsPath, promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprintf(w, "hwinfo_exporter: %s\n", *metricsPath)
	})

	// Under the Windows service manager the server runs until the service
	// is stopped; anywhere else, until it fails.
	run(&http.Server{Addr: *metricsAddr, Handler: mux})
}
