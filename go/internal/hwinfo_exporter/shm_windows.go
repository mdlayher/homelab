//go:build windows

package main

import (
	"errors"
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The names HWiNFO publishes its shared memory and its lock under. HWiNFO
// creates them in the Global namespace, which a service in session 0 can
// open, and only while its sensors window polls with shared memory support
// enabled.
const (
	mappingName = `Global\HWiNFO_SENS_SM2`
	mutexName   = `Global\HWiNFO_SM2_MUTEX`
)

// errNotRunning reports that the mapping does not exist: HWiNFO is not
// running, its sensors window is closed, or shared memory support is off.
var errNotRunning = errors.New("HWiNFO shared memory not found")

// x/sys/windows has no wrapper for OpenFileMappingW.
var procOpenFileMappingW = windows.NewLazySystemDLL("kernel32.dll").NewProc("OpenFileMappingW")

// readShared copies HWiNFO's shared memory and decodes it.
func readShared() (*Snapshot, error) {
	b, err := copyShared()
	if err != nil {
		return nil, err
	}

	return Parse(b)
}

// copyShared copies the in-use part of HWiNFO's shared memory, holding
// HWiNFO's lock when it can so the copy is not torn by an update.
func copyShared() ([]byte, error) {
	name, err := windows.UTF16PtrFromString(mappingName)
	if err != nil {
		return nil, err
	}

	r, _, err := procOpenFileMappingW.Call(windows.FILE_MAP_READ, 0, uintptr(unsafe.Pointer(name)))
	if r == 0 {
		if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) {
			return nil, errNotRunning
		}
		return nil, fmt.Errorf("OpenFileMapping %s: %w", mappingName, err)
	}
	mapping := windows.Handle(r)
	defer windows.CloseHandle(mapping)

	addr, err := windows.MapViewOfFile(mapping, windows.FILE_MAP_READ, 0, 0, 0)
	if err != nil {
		return nil, fmt.Errorf("MapViewOfFile: %w", err)
	}
	defer windows.UnmapViewOfFile(addr)

	// The view's size bounds every read, whatever the header claims.
	var mbi windows.MemoryBasicInformation
	if err := windows.VirtualQuery(addr, &mbi, unsafe.Sizeof(mbi)); err != nil {
		return nil, fmt.Errorf("VirtualQuery: %w", err)
	}

	// The view lives outside the Go heap, so its address is reinterpreted
	// in place rather than converted from a uintptr, which vet flags.
	view := unsafe.Slice((*byte)(*(*unsafe.Pointer)(unsafe.Pointer(&addr))), mbi.RegionSize)

	unlock := lock()
	defer unlock()

	n, err := Size(view)
	if err != nil {
		return nil, err
	}
	if n > len(view) {
		return nil, fmt.Errorf("header describes %d bytes, mapping has %d", n, len(view))
	}

	return append([]byte(nil), view[:n]...), nil
}

// lock takes HWiNFO's shared memory lock if it exists, giving up after a
// short wait: a copy made without it may mix two polls, which one scrape
// can tolerate, but a scrape must never hang on HWiNFO.
func lock() (unlock func()) {
	noop := func() {}

	name, err := windows.UTF16PtrFromString(mutexName)
	if err != nil {
		return noop
	}
	m, err := windows.OpenMutex(windows.SYNCHRONIZE, false, name)
	if err != nil {
		return noop
	}

	switch ev, _ := windows.WaitForSingleObject(m, 100); ev {
	case windows.WAIT_OBJECT_0, windows.WAIT_ABANDONED:
		return func() {
			_ = windows.ReleaseMutex(m)
			_ = windows.CloseHandle(m)
		}
	default:
		_ = windows.CloseHandle(m)
		return noop
	}
}
