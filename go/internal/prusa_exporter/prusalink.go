package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// A Printer is the state of a printer and its current job, as PrusaLink
// reports it.
type Printer struct {
	State                    string
	NozzleTemp, NozzleTarget float64
	BedTemp, BedTarget       float64

	// Job is nil while the printer has no job.
	Job *Job
}

// A Job is the print a printer is running.
type Job struct {
	Name     string
	Progress float64
	Printing time.Duration

	// Remaining is negative while the firmware has no estimate.
	Remaining time.Duration
}

// A Client polls a printer's PrusaLink API.
type Client struct {
	addr, apiKey string
	c            *http.Client
}

// NewClient creates a Client for the printer at addr, a host and optional
// port, authenticating with apiKey.
func NewClient(addr, apiKey string, timeout time.Duration) *Client {
	return &Client{
		addr:   addr,
		apiKey: apiKey,
		c:      &http.Client{Timeout: timeout},
	}
}

// Printer fetches the printer's state and its current job.
func (c *Client) Printer() (*Printer, error) {
	var status struct {
		Printer struct {
			State        string  `json:"state"`
			TempNozzle   float64 `json:"temp_nozzle"`
			TargetNozzle float64 `json:"target_nozzle"`
			TempBed      float64 `json:"temp_bed"`
			TargetBed    float64 `json:"target_bed"`
		} `json:"printer"`
	}
	if _, err := c.get("/api/v1/status", &status); err != nil {
		return nil, err
	}

	p := &Printer{
		State:        status.Printer.State,
		NozzleTemp:   status.Printer.TempNozzle,
		NozzleTarget: status.Printer.TargetNozzle,
		BedTemp:      status.Printer.TempBed,
		BedTarget:    status.Printer.TargetBed,
	}

	// The status carries no file name, so the job comes from its own
	// endpoint, which answers 204 No Content while there is none.
	var job struct {
		Progress      float64 `json:"progress"`
		TimePrinting  int     `json:"time_printing"`
		TimeRemaining *int    `json:"time_remaining"`
		File          struct {
			DisplayName string `json:"display_name"`
		} `json:"file"`
	}
	ok, err := c.get("/api/v1/job", &job)
	if err != nil {
		return nil, err
	}
	if !ok {
		return p, nil
	}

	p.Job = &Job{
		Name:      job.File.DisplayName,
		Progress:  job.Progress / 100,
		Printing:  time.Duration(job.TimePrinting) * time.Second,
		Remaining: -1,
	}
	if job.TimeRemaining != nil {
		p.Job.Remaining = time.Duration(*job.TimeRemaining) * time.Second
	}

	return p, nil
}

// get decodes the JSON body of path into v, reporting false for a 204 No
// Content response.
func (c *Client) get(path string, v any) (bool, error) {
	req, err := http.NewRequest(http.MethodGet, "http://"+c.addr+path, nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("X-Api-Key", c.apiKey)

	res, err := c.c.Do(req)
	if err != nil {
		return false, err
	}
	defer res.Body.Close()

	switch res.StatusCode {
	case http.StatusOK:
	case http.StatusNoContent:
		return false, nil
	default:
		return false, fmt.Errorf("GET %s: %s", path, res.Status)
	}

	if err := json.NewDecoder(res.Body).Decode(v); err != nil {
		return false, fmt.Errorf("GET %s: %v", path, err)
	}
	return true, nil
}
