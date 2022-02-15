package gokrazy

// Forcibly import gokrazy and user packages to allow better go.mod manipulation.
import (
	_ "github.com/gokrazy/breakglass"
	_ "github.com/gokrazy/firmware"
	_ "github.com/gokrazy/gokrazy"
	_ "github.com/gokrazy/kernel"
	_ "github.com/gokrazy/rpi-eeprom"
	_ "github.com/gokrazy/serial-busybox"

	_ "github.com/mdlayher/consrv/cmd/consrv"
	_ "github.com/prometheus/node_exporter"
)
