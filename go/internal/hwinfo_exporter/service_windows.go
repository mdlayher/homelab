//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"time"

	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/eventlog"
)

const serviceName = "hwinfo_exporter"

// run serves srv, as a Windows service when the service manager started the
// process.
func run(srv *http.Server) {
	isService, err := svc.IsWindowsService()
	if err != nil {
		log.Fatalf("cannot detect Windows service: %v", err)
	}
	if !isService {
		log.Printf("starting HWiNFO exporter on %q", srv.Addr)
		if err := srv.ListenAndServe(); err != nil {
			log.Fatalf("cannot serve HWiNFO exporter: %v", err)
		}
		return
	}

	// A service's output goes nowhere, so its messages go to the
	// Application event log. The source is not registered, so Event Viewer
	// prefixes each with a note that its description is missing; the
	// message itself follows.
	elog, err := eventlog.Open(serviceName)
	if err != nil {
		log.Fatalf("cannot open event log: %v", err)
	}
	defer elog.Close()

	if err := svc.Run(serviceName, &service{srv: srv, elog: elog}); err != nil {
		_ = elog.Error(1, fmt.Sprintf("service failed: %v", err))
	}
}

// A service runs the HTTP server under the Windows service manager.
type service struct {
	srv  *http.Server
	elog *eventlog.Log
}

// Execute implements svc.Handler. The service reports that it is running
// only once it holds its port, and a failure to bind ends it with an error
// the service manager records, rather than a start timeout.
func (s *service) Execute(_ []string, req <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}

	l, err := net.Listen("tcp", s.srv.Addr)
	if err != nil {
		_ = s.elog.Error(1, fmt.Sprintf("cannot listen on %q: %v", s.srv.Addr, err))
		return true, 1
	}

	errC := make(chan error, 1)
	go func() { errC <- s.srv.Serve(l) }()

	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	_ = s.elog.Info(1, fmt.Sprintf("serving HWiNFO metrics on %q", s.srv.Addr))

	for {
		select {
		case err := <-errC:
			// The server failed on its own: report it so the service
			// manager's recovery settings can restart it.
			_ = s.elog.Error(1, fmt.Sprintf("server failed: %v", err))
			return true, 2
		case c := <-req:
			switch c.Cmd {
			case svc.Interrogate:
				status <- c.CurrentStatus
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				if err := s.srv.Shutdown(ctx); err != nil && !errors.Is(err, context.DeadlineExceeded) {
					_ = s.elog.Warning(1, fmt.Sprintf("shutdown: %v", err))
				}
				cancel()
				return false, 0
			}
		}
	}
}
