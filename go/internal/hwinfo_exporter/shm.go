package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"time"
	"unicode/utf8"
)

// HWiNFO's shared memory interface: a header, then a section of sensor
// elements and a section of reading elements. The header gives each
// section's offset, element size and element count, and newer revisions of
// the interface append fields to the end of each element, so elements are
// decoded by their known prefix and stepped over by the size the header
// declares. Every integer is little-endian and every struct is packed.
const (
	// headerLen is the header through dwPollingPeriod.
	headerLen = 48

	// stringLen and unitLen are the fixed sizes of HWiNFO's string fields.
	stringLen = 128
	unitLen   = 16

	// sensorLen is a sensor element through szSensorNameUser, and
	// sensorUTF8Len adds utfSensorNameUser.
	sensorLen     = 4 + 4 + stringLen + stringLen
	sensorUTF8Len = sensorLen + stringLen

	// readingLen is a reading element through ValueAvg, and readingUTF8Len
	// adds utfLabelUser and utfUnit.
	readingLen     = 4 + 4 + 4 + stringLen + stringLen + unitLen + 4*8
	readingUTF8Len = readingLen + stringLen + unitLen
)

// Signatures in the header's first field: active while HWiNFO shares sensor
// data, dead once sharing has stopped.
var (
	signatureActive = [4]byte{'H', 'W', 'i', 'S'}
	signatureDead   = [4]byte{'D', 'E', 'A', 'D'}
)

// errInactive reports that HWiNFO has stopped sharing sensor data.
var errInactive = errors.New("HWiNFO shared memory is inactive")

// A ReadingType is the kind of quantity a Reading measures.
type ReadingType uint32

// Reading types defined by the interface.
const (
	TypeNone ReadingType = iota
	TypeTemperature
	TypeVoltage
	TypeFan
	TypeCurrent
	TypePower
	TypeClock
	TypeUsage
	TypeOther
)

// String returns the label value used for t in metrics.
func (t ReadingType) String() string {
	switch t {
	case TypeNone:
		return "none"
	case TypeTemperature:
		return "temperature"
	case TypeVoltage:
		return "voltage"
	case TypeFan:
		return "fan"
	case TypeCurrent:
		return "current"
	case TypePower:
		return "power"
	case TypeClock:
		return "clock"
	case TypeUsage:
		return "usage"
	case TypeOther:
		return "other"
	default:
		return fmt.Sprintf("unknown_%d", uint32(t))
	}
}

// A Snapshot is one decoded copy of HWiNFO's shared memory.
type Snapshot struct {
	Version, Revision uint32
	PollTime          time.Time
	PollingPeriod     time.Duration
	Sensors           []Sensor
	Readings          []Reading
}

// A Sensor is a device HWiNFO reads, such as a CPU, a motherboard's
// monitoring chip or a GPU. ID and Instance together identify it.
type Sensor struct {
	ID, Instance uint32
	// Name is the name shown in HWiNFO, which the user may have changed.
	Name string
}

// A Reading is one value from a Sensor.
type Reading struct {
	Type ReadingType
	// Sensor is the index of the reading's sensor in Snapshot.Sensors.
	Sensor int
	ID     uint32
	// Label and Unit are as shown in HWiNFO; the user may have renamed the
	// label.
	Label, Unit string
	Value       float64
}

// Size reports how many bytes of shared memory the header in b says are in
// use, so a reader can copy exactly that much. b must hold the header.
func Size(b []byte) (int, error) {
	h, err := parseHeader(b)
	if err != nil {
		return 0, err
	}

	return h.size(), nil
}

// Parse decodes a copy of HWiNFO's shared memory.
func Parse(b []byte) (*Snapshot, error) {
	h, err := parseHeader(b)
	if err != nil {
		return nil, err
	}
	if n := h.size(); n > len(b) {
		return nil, fmt.Errorf("header describes %d bytes, have %d", n, len(b))
	}

	s := &Snapshot{
		Version:       h.version,
		Revision:      h.revision,
		PollTime:      time.Unix(h.pollTime, 0),
		PollingPeriod: time.Duration(h.pollingPeriod) * time.Millisecond,
		Sensors:       make([]Sensor, 0, h.sensors.count),
		Readings:      make([]Reading, 0, h.readings.count),
	}

	for i := range h.sensors.count {
		e := h.sensors.element(b, i)
		name := ansi(e[8+stringLen : sensorLen])
		if len(e) >= sensorUTF8Len {
			if u := cstring(e[sensorLen:sensorUTF8Len]); u != "" && utf8.ValidString(u) {
				name = u
			}
		}

		s.Sensors = append(s.Sensors, Sensor{
			ID:       binary.LittleEndian.Uint32(e[0:4]),
			Instance: binary.LittleEndian.Uint32(e[4:8]),
			Name:     name,
		})
	}

	for i := range h.readings.count {
		e := h.readings.element(b, i)

		sensor := int(binary.LittleEndian.Uint32(e[4:8]))
		if sensor >= len(s.Sensors) {
			return nil, fmt.Errorf("reading %d refers to sensor %d of %d", i, sensor, len(s.Sensors))
		}

		const (
			labelUser = 12 + stringLen
			unit      = labelUser + stringLen
			value     = unit + unitLen
		)

		label, u := ansi(e[labelUser:unit]), ansi(e[unit:value])
		if len(e) >= readingUTF8Len {
			if l := cstring(e[readingLen : readingLen+stringLen]); l != "" && utf8.ValidString(l) {
				label = l
			}
			if v := cstring(e[readingLen+stringLen : readingUTF8Len]); utf8.ValidString(v) {
				u = v
			}
		}

		s.Readings = append(s.Readings, Reading{
			Type:   ReadingType(binary.LittleEndian.Uint32(e[0:4])),
			Sensor: sensor,
			ID:     binary.LittleEndian.Uint32(e[8:12]),
			Label:  label,
			Unit:   u,
			Value:  math.Float64frombits(binary.LittleEndian.Uint64(e[value : value+8])),
		})
	}

	return s, nil
}

// A header is the decoded shared memory header.
type header struct {
	version, revision uint32
	pollTime          int64
	pollingPeriod     uint32
	sensors, readings section
}

// A section is one array of fixed-size elements.
type section struct {
	offset, size, count int
}

// end is the offset just past the section's last element.
func (s section) end() int { return s.offset + s.size*s.count }

// element returns the i'th element of the section in b.
func (s section) element(b []byte, i int) []byte {
	off := s.offset + i*s.size
	return b[off : off+s.size]
}

// size is the number of bytes the header and both sections occupy.
func (h header) size() int { return max(headerLen, h.sensors.end(), h.readings.end()) }

func parseHeader(b []byte) (header, error) {
	if len(b) < headerLen {
		return header{}, fmt.Errorf("need %d header bytes, have %d", headerLen, len(b))
	}

	switch sig := [4]byte(b[0:4]); sig {
	case signatureActive:
	case signatureDead:
		return header{}, errInactive
	default:
		return header{}, fmt.Errorf("unrecognized signature %q", sig[:])
	}

	u32 := func(off int) uint32 { return binary.LittleEndian.Uint32(b[off : off+4]) }
	sec := func(off int) section {
		return section{offset: int(u32(off)), size: int(u32(off + 4)), count: int(u32(off + 8))}
	}

	h := header{
		version:       u32(4),
		revision:      u32(8),
		pollTime:      int64(binary.LittleEndian.Uint64(b[12:20])),
		sensors:       sec(20),
		readings:      sec(32),
		pollingPeriod: u32(44),
	}

	// Bound every field before any arithmetic on it, so a corrupt header
	// cannot overflow an offset or demand a huge allocation.
	const limit = 1 << 26
	for _, c := range []struct {
		name     string
		s        section
		elemSize int
	}{
		{"sensor", h.sensors, sensorLen},
		{"reading", h.readings, readingLen},
	} {
		switch {
		case c.s.size < c.elemSize:
			return header{}, fmt.Errorf("%s elements are %d bytes, need at least %d", c.name, c.s.size, c.elemSize)
		case c.s.offset < headerLen || c.s.offset > limit, c.s.size > limit, c.s.count > limit/c.s.size:
			return header{}, fmt.Errorf("%s section out of range: offset %d, size %d, count %d",
				c.name, c.s.offset, c.s.size, c.s.count)
		}
	}

	return h, nil
}

// cstring returns the NUL-terminated string at the start of b, without the
// surrounding spaces HWiNFO pads some names with.
func cstring(b []byte) string {
	if i := bytes.IndexByte(b, 0); i >= 0 {
		b = b[:i]
	}
	return string(bytes.TrimSpace(b))
}

// ansi decodes a NUL-terminated string in Windows-1252, the code page
// HWiNFO's non-UTF-8 fields use on an English Windows.
func ansi(b []byte) string {
	s := cstring(b)
	r := make([]rune, 0, len(s))
	for i := range len(s) {
		c := s[i]
		switch {
		case c >= 0x80 && c <= 0x9f && cp1252[c-0x80] != 0:
			r = append(r, cp1252[c-0x80])
		default:
			// The rest of Windows-1252 coincides with Latin-1, and the five
			// undefined bytes keep their Latin-1 control code points.
			r = append(r, rune(c))
		}
	}
	return string(r)
}

// cp1252 maps Windows-1252's 0x80-0x9f range, where it departs from Latin-1.
var cp1252 = [32]rune{
	0x20ac, 0, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
	0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017d, 0,
	0, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
	0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0, 0x017e, 0x0178,
}
