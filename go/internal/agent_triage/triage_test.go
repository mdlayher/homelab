package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
)

func TestTriagerAdmit(t *testing.T) {
	now := time.Unix(1791084198, 0)
	tr := testTriager(&now)
	firing := func(key string) payload { return payload{Status: "firing", GroupKey: key} }

	steps := []struct {
		name    string
		advance time.Duration
		p       payload
		finish  string
		ok      bool
	}{
		{name: "resolved", p: payload{Status: "resolved", GroupKey: "a"}},
		{name: "first", p: firing("a"), ok: true},
		{name: "in flight", p: firing("a")},
		// Finished, but inside the cooldown.
		{name: "cooldown", p: firing("a"), finish: "a"},
		{name: "after cooldown", advance: 7 * time.Hour, p: firing("a"), finish: "a", ok: true},
		{name: "second group", p: firing("b"), ok: true},
		{name: "third group", p: firing("c"), ok: true},
		// The per-hour limit is 3, and a, b and c started this hour.
		{name: "hourly limit", p: firing("d")},
		{name: "next hour", advance: time.Hour, p: firing("d"), ok: true},
	}

	for _, s := range steps {
		now = now.Add(s.advance)
		if s.finish != "" {
			tr.mu.Lock()
			delete(tr.inFlight, s.finish)
			tr.mu.Unlock()
		}

		if _, ok := tr.admit(s.p); ok != s.ok {
			t.Fatalf("%s: admitted %v, want %v", s.name, ok, s.ok)
		}
	}
}

func TestTriagerServeHTTP(t *testing.T) {
	now := time.Unix(1791084198, 0)
	tr := testTriager(&now)

	var (
		mu    sync.Mutex
		posts []string
	)
	tr.diagnose = func(_ context.Context, p payload, raw []byte) (string, error) {
		if !strings.Contains(prompt(raw, "/home/u"), `"alertname": "FanStopped"`) {
			return "", errors.New("prompt is missing the payload")
		}
		return "fan1 on the server stopped at 02:00", nil
	}
	tr.post = func(_ context.Context, title, body string) error {
		mu.Lock()
		defer mu.Unlock()
		posts = append(posts, title+": "+body)
		return nil
	}

	srv := httptest.NewServer(tr)
	defer srv.Close()

	body := `{"status":"firing","groupKey":"{}:{alertname=\"FanStopped\"}","commonLabels":{"alertname":"FanStopped"},` +
		`"alerts":[{"status":"firing","labels":{"alertname":"FanStopped","sensor":"fan1"}}]}`

	// The same group twice: the second is skipped while the first runs or
	// cools down, and both requests are accepted.
	for range 2 {
		res, err := http.Post(srv.URL, "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatalf("failed to post: %v", err)
		}
		_ = res.Body.Close()
		if res.StatusCode != http.StatusAccepted {
			t.Fatalf("unexpected status: %d", res.StatusCode)
		}
	}
	tr.Wait()

	want := []string{"Diagnosis: FanStopped: fan1 on the server stopped at 02:00"}
	if diff := cmp.Diff(want, posts); diff != "" {
		t.Fatalf("unexpected posts (-want +got):\n%s", diff)
	}
}

func TestTriagerDiagnoseFailure(t *testing.T) {
	now := time.Unix(1791084198, 0)
	tr := testTriager(&now)
	tr.diagnose = func(context.Context, payload, []byte) (string, error) {
		return "", errors.New("systemd-run: exit status 1")
	}

	var got string
	tr.post = func(_ context.Context, title, body string) error {
		got = title + ": " + body
		return nil
	}

	tr.run(payload{Status: "firing", GroupKey: "a", CommonLabels: map[string]string{"alertname": "X"}}, []byte("{}"))

	want := "Diagnosis: X: The diagnosis failed: systemd-run: exit status 1"
	if diff := cmp.Diff(want, got); diff != "" {
		t.Fatalf("unexpected post (-want +got):\n%s", diff)
	}
}

func TestPayloadName(t *testing.T) {
	var p payload
	if err := json.Unmarshal([]byte(`{"alerts":[{"labels":{"alertname":"B"}},{"labels":{"alertname":"A"}},{"labels":{"alertname":"B"}}]}`), &p); err != nil {
		t.Fatalf("failed to decode: %v", err)
	}
	if diff := cmp.Diff("A, B", p.name()); diff != "" {
		t.Fatalf("unexpected name (-want +got):\n%s", diff)
	}
}

func TestDiscord(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &got)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	post := discord(srv.Client(), func() (string, error) { return srv.URL, nil })
	if err := post(context.Background(), "Diagnosis: X", strings.Repeat("é", 3000)); err != nil {
		t.Fatalf("failed to post: %v", err)
	}

	content := got["content"].(string)
	if n := len([]rune(content)); n != 2000 {
		t.Fatalf("content is %d runes, want 2000", n)
	}
	if !strings.HasPrefix(content, "**Diagnosis: X**\n") || !strings.HasSuffix(content, "...") {
		t.Fatalf("unexpected content framing: %q...", content[:40])
	}
	if diff := cmp.Diff(map[string]any{"parse": []any{}}, got["allowed_mentions"]); diff != "" {
		t.Fatalf("unexpected allowed_mentions (-want +got):\n%s", diff)
	}
}

func TestDiscordError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "bad webhook", http.StatusNotFound)
	}))
	defer srv.Close()

	post := discord(srv.Client(), func() (string, error) { return srv.URL, nil })
	if err := post(context.Background(), "t", "b"); err == nil || !strings.Contains(err.Error(), "HTTP 404") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func testTriager(now *time.Time) *triager {
	return &triager{
		diagnose: func(context.Context, payload, []byte) (string, error) { return "ok", nil },
		post:     func(context.Context, string, string) error { return nil },
		timeout:  time.Minute,
		cooldown: 6 * time.Hour,
		perHour:  3,
		now:      func() time.Time { return *now },
		inFlight: map[string]bool{},
		last:     map[string]time.Time{},
	}
}

func TestDiscordRedactsURL(t *testing.T) {
	// Nothing listens here, so the request fails before any response.
	srv := httptest.NewServer(http.NotFoundHandler())
	u := srv.URL + "/api/webhooks/1/secret-token"
	srv.Close()

	post := discord(srv.Client(), func() (string, error) { return u, nil })
	err := post(context.Background(), "t", "b")
	if err == nil {
		t.Fatal("expected an error")
	}
	if strings.Contains(err.Error(), "secret-token") {
		t.Fatalf("error leaks the webhook URL: %v", err)
	}
}
