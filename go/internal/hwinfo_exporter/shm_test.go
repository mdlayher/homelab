package main

import (
	"encoding/binary"
	"errors"
	"math"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
)

func TestParse(t *testing.T) {
	sensors := []testSensor{
		// HWiNFO pads some names with spaces.
		{id: 0xf0000101, name: "System: ASUS ", utf8: "System: ASUS "},
		{id: 0xf0000200, inst: 1, name: "WireView Pro II", utf8: "WireView Pro II"},
	}
	readings := []testReading{
		{typ: TypeOther, sensor: 0, id: 0x08000000, label: "Virtual Memory Committed", unit: "MB", value: 14689},
		{typ: TypeCurrent, sensor: 1, id: 0x03000003, label: "Pin 3 Current", unit: "A", value: 7.25},
		// The ANSI field holds the Windows-1252 degree sign, the UTF-8 one
		// its UTF-8 encoding.
		{typ: TypeTemperature, sensor: 1, id: 0x01000000, label: "Connector Temp", unit: "\xb0C", utf8Unit: "°C", value: 41.5},
	}

	want := &Snapshot{
		Version:       2,
		Revision:      1,
		PollTime:      time.Unix(1791084198, 0),
		PollingPeriod: 2 * time.Second,
		Sensors: []Sensor{
			{ID: 0xf0000101, Name: "System: ASUS"},
			{ID: 0xf0000200, Instance: 1, Name: "WireView Pro II"},
		},
		Readings: []Reading{
			{Type: TypeOther, Sensor: 0, ID: 0x08000000, Label: "Virtual Memory Committed", Unit: "MB", Value: 14689},
			{Type: TypeCurrent, Sensor: 1, ID: 0x03000003, Label: "Pin 3 Current", Unit: "A", Value: 7.25},
			{Type: TypeTemperature, Sensor: 1, ID: 0x01000000, Label: "Connector Temp", Unit: "°C", Value: 41.5},
		},
	}

	tests := []struct {
		name string
		b    []byte
	}{
		{
			name: "UTF-8 fields",
			b:    encode(sensorUTF8Len, readingUTF8Len, sensors, readings),
		},
		{
			// An older revision without the UTF-8 fields: the ANSI ones
			// are decoded as Windows-1252.
			name: "ANSI fields",
			b:    encode(sensorLen, readingLen, sensors, readings),
		},
		{
			// A newer revision appending fields this decoder does not
			// know: elements are stepped over by their declared size.
			name: "larger elements",
			b:    encode(sensorUTF8Len+64, readingUTF8Len+64, sensors, readings),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Parse(tt.b)
			if err != nil {
				t.Fatalf("failed to parse: %v", err)
			}

			if diff := cmp.Diff(want, got); diff != "" {
				t.Fatalf("unexpected snapshot (-want +got):\n%s", diff)
			}

			n, err := Size(tt.b)
			if err != nil {
				t.Fatalf("failed to size: %v", err)
			}
			if n != len(tt.b) {
				t.Fatalf("size %d, encoded %d", n, len(tt.b))
			}
		})
	}
}

func TestParseErrors(t *testing.T) {
	sensors := []testSensor{{id: 1, name: "s"}}
	readings := []testReading{{sensor: 0, label: "r"}}
	valid := func() []byte { return encode(sensorUTF8Len, readingUTF8Len, sensors, readings) }

	tests := []struct {
		name  string
		b     func() []byte
		check func(error) bool
	}{
		{
			name: "short header",
			b:    func() []byte { return valid()[:headerLen-1] },
		},
		{
			name: "dead",
			b: func() []byte {
				b := valid()
				copy(b, "DEAD")
				return b
			},
			check: func(err error) bool { return errors.Is(err, errInactive) },
		},
		{
			name: "bad signature",
			b: func() []byte {
				b := valid()
				copy(b, "nope")
				return b
			},
		},
		{
			name: "truncated",
			b:    func() []byte { b := valid(); return b[:len(b)-1] },
		},
		{
			name: "small elements",
			b: func() []byte {
				b := valid()
				binary.LittleEndian.PutUint32(b[24:], sensorLen-1)
				return b
			},
		},
		{
			name: "offset inside header",
			b: func() []byte {
				b := valid()
				binary.LittleEndian.PutUint32(b[20:], headerLen-1)
				return b
			},
		},
		{
			name: "huge count",
			b: func() []byte {
				b := valid()
				binary.LittleEndian.PutUint32(b[40:], math.MaxUint32)
				return b
			},
		},
		{
			name: "dangling sensor index",
			b: func() []byte {
				b := valid()
				off := headerLen + sensorUTF8Len*len(sensors)
				binary.LittleEndian.PutUint32(b[off+4:], 1)
				return b
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Parse(tt.b())
			if err == nil {
				t.Fatal("expected an error, but none occurred")
			}
			if tt.check != nil && !tt.check(err) {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}

func Test_ansi(t *testing.T) {
	// Windows-1252 bytes which differ from Latin-1 (euro sign, trade mark),
	// one which matches it (degree sign), and an undefined one.
	got := ansi([]byte("\x80 \x99 \xb0 \x81\x00ignored"))
	if diff := cmp.Diff("€ ™ ° \u0081", got); diff != "" {
		t.Fatalf("unexpected string (-want +got):\n%s", diff)
	}
}

type testSensor struct {
	id, inst   uint32
	name, utf8 string
}

type testReading struct {
	typ         ReadingType
	sensor      int
	id          uint32
	label, unit string
	utf8Unit    string
	value       float64
}

// encode builds HWiNFO shared memory with the given element sizes; elements
// large enough get the UTF-8 fields, copied from the ANSI ones when a test
// does not set them.
func encode(sensorSize, readingSize int, sensors []testSensor, readings []testReading) []byte {
	sensorOff := headerLen
	readingOff := sensorOff + sensorSize*len(sensors)
	b := make([]byte, readingOff+readingSize*len(readings))

	copy(b, "HWiS")
	put := func(off int, v uint32) { binary.LittleEndian.PutUint32(b[off:], v) }
	put(4, 2)
	put(8, 1)
	binary.LittleEndian.PutUint64(b[12:], 1791084198)
	put(20, uint32(sensorOff))
	put(24, uint32(sensorSize))
	put(28, uint32(len(sensors)))
	put(32, uint32(readingOff))
	put(36, uint32(readingSize))
	put(40, uint32(len(readings)))
	put(44, 2000)

	for i, s := range sensors {
		e := b[sensorOff+i*sensorSize:]
		binary.LittleEndian.PutUint32(e[0:], s.id)
		binary.LittleEndian.PutUint32(e[4:], s.inst)
		copy(e[8:8+stringLen], s.name)
		copy(e[8+stringLen:sensorLen], s.name)
		if sensorSize >= sensorUTF8Len {
			copy(e[sensorLen:sensorUTF8Len], or(s.utf8, s.name))
		}
	}

	for i, r := range readings {
		e := b[readingOff+i*readingSize:]
		binary.LittleEndian.PutUint32(e[0:], uint32(r.typ))
		binary.LittleEndian.PutUint32(e[4:], uint32(r.sensor))
		binary.LittleEndian.PutUint32(e[8:], r.id)
		copy(e[12:12+stringLen], r.label)
		copy(e[12+stringLen:12+2*stringLen], r.label)
		copy(e[12+2*stringLen:12+2*stringLen+unitLen], r.unit)
		v := 12 + 2*stringLen + unitLen
		for j := range 4 {
			binary.LittleEndian.PutUint64(e[v+8*j:], math.Float64bits(r.value))
		}
		if readingSize >= readingUTF8Len {
			copy(e[readingLen:readingLen+stringLen], r.label)
			copy(e[readingLen+stringLen:readingUTF8Len], or(r.utf8Unit, r.unit))
		}
	}

	return b
}

func or(s, def string) string {
	if s != "" {
		return s
	}
	return def
}
