// Command agent_triage receives Alertmanager webhooks and has an agent
// diagnose each newly firing alert group, posting the diagnosis to Discord.
// The agent runs read-only, inside the development container where its
// query helpers live.
package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func main() {
	var (
		addr     = flag.String("addr", "127.0.0.1:9097", "address to receive Alertmanager webhooks on")
		discordF = flag.String("discord-url-file", "", "file holding the Discord webhook URL to post diagnoses to")

		machine = flag.String("machine", "linuxdev", "container the agent runs in")
		root    = flag.String("container-root", "/var/lib/nixos-containers/linuxdev", "the container's root filesystem on this host")
		dir     = flag.String("handoff-dir", "/var/lib/agent-triage", "directory inside the container for prompts and output")
		user    = flag.String("user", "mdlayher", "container user the agent runs as")
		workdir = flag.String("workdir", "/home/mdlayher/src/homelab/main", "the agent's working directory inside the container")
		claude  = flag.String("claude", "/run/current-system/sw/bin/claude", "the agent command inside the container")
		model   = flag.String("model", "", "model for the agent; empty for the user's default")
		budget  = flag.String("max-budget-usd", "2", "spending limit for one diagnosis")

		timeout  = flag.Duration("timeout", 10*time.Minute, "longest a diagnosis may run")
		cooldown = flag.Duration("cooldown", 6*time.Hour, "shortest time between two diagnoses of one alert group")
		perHour  = flag.Int("per-hour", 4, "most diagnoses started in any hour")
	)
	flag.Parse()

	if *discordF == "" {
		log.Fatal("-discord-url-file is required")
	}

	// The agent may run only the read-only query helpers and read files in
	// its working directory and the skill files: --restricted drops every
	// tool which runs code and ignores the user's settings files and skills,
	// so nothing there widens it.
	helpers := []string{"promq", "promrange", "lokiq", "amq"}
	var allowed []string
	for _, h := range helpers {
		allowed = append(allowed,
			"Bash(/home/"+*user+"/.claude/bin/"+h+":*)",
			"Bash(~/.claude/bin/"+h+":*)",
		)
	}
	argv := []string{
		*claude, "-p",
		"--restricted",
		"--tools", "Bash,Read,Grep,Glob,SendMessage",
		"--allowedTools", strings.Join(allowed, ","),
		"--add-dir", "/home/" + *user + "/.claude/skills",
		"--no-session-persistence",
		"--max-budget-usd", *budget,
	}
	if *model != "" {
		argv = append(argv, "--model", *model)
	}

	c := &container{
		machine: *machine,
		root:    *root,
		dir:     *dir,
		user:    *user,
		home:    "/home/" + *user,
		workdir: *workdir,
		argv:    argv,
		maxRun:  strconv.Itoa(int(timeout.Seconds())),
	}

	t := &triager{
		diagnose: c.diagnose,
		post: discord(&http.Client{Timeout: 30 * time.Second}, func() (string, error) {
			b, err := os.ReadFile(*discordF)
			return strings.TrimSpace(string(b)), err
		}),
		timeout:  *timeout,
		cooldown: *cooldown,
		perHour:  *perHour,
		now:      time.Now,
		inFlight: map[string]bool{},
		last:     map[string]time.Time{},
	}

	srv := &http.Server{Addr: *addr, Handler: t, ReadHeaderTimeout: 10 * time.Second}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		_ = srv.Shutdown(context.Background())
	}()

	log.Printf("receiving Alertmanager webhooks on %q", *addr)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("cannot serve: %v", err)
	}

	// Let running diagnoses post before exiting.
	t.Wait()
}
