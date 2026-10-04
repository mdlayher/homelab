package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// A container runs diagnoses inside a systemd-nspawn container as one of
// its users, where the agent and its query helpers live. The prompt and the
// output pass through files under dir inside the container, which this
// process reaches through the container's root on the host; systemd opens
// both for the unit, so no pipe crosses into the container.
type container struct {
	machine string // machine name, as systemd-run --machine takes it
	root    string // the container's root filesystem on the host
	dir     string // the handoff directory, as a path inside the container
	user    string
	home    string
	workdir string
	argv    []string // the agent command and its flags
	maxRun  string   // RuntimeMaxSec for the unit
}

// diagnose runs the agent on the prompt for raw and returns what it printed.
func (c *container) diagnose(ctx context.Context, _ payload, raw []byte) (string, error) {
	id, err := randomID()
	if err != nil {
		return "", err
	}
	// The unit and the agent's session share the name, so a message from
	// the session leads to the unit's journal.
	name := "agent-triage-" + id

	var (
		in, out = filepath.Join(c.dir, id+".prompt"), filepath.Join(c.dir, id+".out")
		hostIn  = filepath.Join(c.root, in)
		hostOut = filepath.Join(c.root, out)
	)
	if err := os.MkdirAll(filepath.Join(c.root, c.dir), 0o700); err != nil {
		return "", err
	}

	// Created exclusively: a run that draws a running run's ID fails here,
	// before it can touch the other's files.
	f, err := os.OpenFile(hostIn, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", err
	}
	defer os.Remove(hostIn)
	defer os.Remove(hostOut)

	_, err = f.WriteString(prompt(raw, c.home))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return "", err
	}

	args := []string{
		"--machine=" + c.machine,
		"--uid=" + c.user,
		"--wait", "--collect", "--quiet",
		"--unit=" + name,
		"--working-directory=" + c.workdir,
		"--setenv=HOME=" + c.home,
		"--setenv=PATH=/run/current-system/sw/bin:/etc/profiles/per-user/" + c.user + "/bin",
		"--property=StandardInput=file:" + in,
		"--property=StandardOutput=file:" + out,
		"--property=RuntimeMaxSec=" + c.maxRun,
		"--",
	}
	log.Printf("running %s", name)
	argv := append(append(args, c.argv...), "--name", name)
	cmd := exec.CommandContext(ctx, "systemd-run", argv...)
	msg, err := cmd.CombinedOutput()

	// The output file holds whatever the agent managed to write, which is
	// worth posting even when the run failed.
	res, rerr := os.ReadFile(hostOut)
	body := strings.TrimSpace(string(res))

	switch {
	case err != nil && body == "":
		return "", fmt.Errorf("systemd-run: %v: %s", err, strings.TrimSpace(string(msg)))
	case err != nil:
		return body + "\n\n(The run did not finish cleanly: " + err.Error() + ")", nil
	case rerr != nil:
		return "", fmt.Errorf("reading output: %v", rerr)
	case body == "":
		return "", fmt.Errorf("the agent printed nothing")
	default:
		return body, nil
	}
}

func randomID() (string, error) {
	b := make([]byte, 2)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
