//go:build !windows

package main

import "errors"

// errNotRunning reports that HWiNFO's shared memory does not exist, which is
// always the case off Windows.
var errNotRunning = errors.New("HWiNFO shared memory not found")

// readShared always fails off Windows; the decoder and collector are
// platform independent and tested everywhere.
func readShared() (*Snapshot, error) { return nil, errNotRunning }
