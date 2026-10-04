package main

import (
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestCollector(t *testing.T) {
	poll := time.Unix(1791084198, 0)
	c := NewCollector(func() (*Snapshot, error) {
		return &Snapshot{
			PollTime:      poll,
			PollingPeriod: 2 * time.Second,
			Sensors: []Sensor{
				{ID: 0xf0000200, Instance: 1, Name: "WireView Pro II"},
				// Names repeat across instances, as with memory modules.
				{ID: 0xe0000100, Instance: 0, Name: "DIMM"},
				{ID: 0xe0000100, Instance: 1, Name: "DIMM"},
			},
			Readings: []Reading{
				{Type: TypeCurrent, Sensor: 0, Label: "Pin 3 Current", Unit: "A", Value: 7.25},
				{Type: TypeTemperature, Sensor: 0, Label: "Connector Temp", Unit: "°C", Value: 41.5},
				// A repeated label within one sensor: the first wins.
				{Type: TypeTemperature, Sensor: 0, Label: "Connector Temp", Unit: "°C", Value: 99},
				{Type: TypeTemperature, Sensor: 1, Label: "Temperature", Unit: "°C", Value: 35.25},
				{Type: TypeTemperature, Sensor: 2, Label: "Temperature", Unit: "°C", Value: 36.5},
			},
		}, nil
	}).(*collector)
	c.now = func() time.Time { return poll.Add(1500 * time.Millisecond) }

	const want = `
# HELP hwinfo_poll_age_seconds Seconds since HWiNFO last updated its sensor readings.
# TYPE hwinfo_poll_age_seconds gauge
hwinfo_poll_age_seconds 1.5
# HELP hwinfo_polling_period_seconds How often HWiNFO updates its sensor readings.
# TYPE hwinfo_polling_period_seconds gauge
hwinfo_polling_period_seconds 2
# HELP hwinfo_sensor_info A sensor HWiNFO reads, always 1.
# TYPE hwinfo_sensor_info gauge
hwinfo_sensor_info{sensor="DIMM",sensor_id="e0000100_0"} 1
hwinfo_sensor_info{sensor="DIMM",sensor_id="e0000100_1"} 1
hwinfo_sensor_info{sensor="WireView Pro II",sensor_id="f0000200_1"} 1
# HELP hwinfo_sensor_value A sensor reading as HWiNFO reports it, in the unit its unit label names.
# TYPE hwinfo_sensor_value gauge
hwinfo_sensor_value{label="Connector Temp",sensor="WireView Pro II",sensor_id="f0000200_1",type="temperature",unit="°C"} 41.5
hwinfo_sensor_value{label="Pin 3 Current",sensor="WireView Pro II",sensor_id="f0000200_1",type="current",unit="A"} 7.25
hwinfo_sensor_value{label="Temperature",sensor="DIMM",sensor_id="e0000100_0",type="temperature",unit="°C"} 35.25
hwinfo_sensor_value{label="Temperature",sensor="DIMM",sensor_id="e0000100_1",type="temperature",unit="°C"} 36.5
# HELP hwinfo_up Whether HWiNFO's shared memory was read and is active.
# TYPE hwinfo_up gauge
hwinfo_up 1
`

	if err := testutil.CollectAndCompare(c, strings.NewReader(want)); err != nil {
		t.Fatalf("unexpected metrics: %v", err)
	}
}

func TestCollectorDown(t *testing.T) {
	for _, err := range []error{errNotRunning, errInactive} {
		c := NewCollector(func() (*Snapshot, error) { return nil, err })

		const want = `
# HELP hwinfo_up Whether HWiNFO's shared memory was read and is active.
# TYPE hwinfo_up gauge
hwinfo_up 0
`

		if err := testutil.CollectAndCompare(c, strings.NewReader(want)); err != nil {
			t.Fatalf("unexpected metrics: %v", err)
		}
	}
}
