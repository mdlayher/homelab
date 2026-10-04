//go:build !windows

package main

import (
	"log"
	"net/http"
)

// run serves srv until it fails.
func run(srv *http.Server) {
	log.Printf("starting HWiNFO exporter on %q", srv.Addr)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("cannot serve HWiNFO exporter: %v", err)
	}
}
