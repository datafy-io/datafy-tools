package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/datafy-io/datafy-tools/desktop-app/internal/protocol"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/scanner"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/session"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/sso"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/testutil/fakeidc"
)

const (
	origin = "https://app.example.com"
	nonce  = "launch-secret-0123456789"
	acct1  = "111111111111"
	acct2  = "222222222222"
)

var allowed = func(o string) bool { return o == origin }

func link(o, n string) string {
	return "datafy-discovery://open?origin=" + url.QueryEscape(o) + "&nonce=" + n
}

const scanFile = `{"record_type":"region","account_id":"111111111111","region":"us-east-1","status":"ok","volumes":[],"instances":[]}
{"record_type":"summary","tool_version":"0.2.1","scanned_at":"2026-01-01T00:00:00Z","interrupted":false,"accounts_total":1,"accounts_scanned":1,"accounts_skipped":0,"accounts_failed":0,"regions_scanned":1,"regions_partial":0,"regions_failed":0}
`

type harness struct {
	t       *testing.T
	idc     *fakeidc.Server
	port    int
	opened  []string
	mu      sync.Mutex
	stopped chan struct{} // closed when Run returns
	err     error
	cancel  context.CancelFunc
	envOut  string
}

// start runs the whole app: the real SSO client against the fake Identity Center, the real scanner executor running a
// fake scanner script, and the real HTTP API.
func start(t *testing.T, mod func(*Config)) *harness {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script scanner")
	}
	h := &harness{t: t, idc: fakeidc.New(t), stopped: make(chan struct{})}
	h.idc.Accounts = []map[string]string{{"accountId": acct1, "accountName": "management"}, {"accountId": acct2, "accountName": "dev"}}
	h.idc.Roles = map[string][]string{acct1: {"Admin", "ReadOnly"}, acct2: {"Admin"}}

	dir := t.TempDir()
	src := filepath.Join(dir, "scan.src")
	_ = os.WriteFile(src, []byte(scanFile), 0o600)
	h.envOut = filepath.Join(dir, "env.txt")
	bin := filepath.Join(dir, "scanner")
	_ = os.WriteFile(bin, []byte("#!/bin/sh\nenv > '"+h.envOut+"'\ncp '"+src+"' \"$2\"\n"), 0o700)

	ports := make(chan int, 1)
	cfg := Config{
		Port: 0, Version: "9.9.9", Allowed: allowed,
		NewSSO: func(region string) session.SSO {
			return sso.New(region, sso.WithEndpoints(h.idc.URL, h.idc.URL),
				sso.WithClock(time.Now, func(ctx context.Context, d time.Duration) error { time.Sleep(15 * time.Millisecond); return ctx.Err() }))
		},
		Runner:  scanner.Exec{Binary: bin},
		OpenURL: func(u string) error { h.mu.Lock(); h.opened = append(h.opened, u); h.mu.Unlock(); return nil },
		Profiles: func() ([]sso.Profile, error) {
			return []sso.Profile{{Name: "management", StartURL: "https://d-1.awsapps.com/start", Region: "us-east-1"}}, nil
		},
		Interval: 40 * time.Millisecond, MinGap: 5 * time.Millisecond, IdleLimit: time.Hour,
		OnListen: func(p int) { ports <- p },
	}
	if mod != nil {
		mod(&cfg)
	}
	ctx, cancel := context.WithCancel(context.Background())
	h.cancel = cancel
	go func() { h.err = Run(ctx, cfg, link(origin, nonce)); close(h.stopped) }()
	select {
	case h.port = <-ports:
	case <-h.stopped:
		t.Fatalf("the app did not start: %v", h.err)
	case <-time.After(3 * time.Second):
		t.Fatal("the app did not start")
	}
	t.Cleanup(func() {
		cancel()
		select {
		case <-h.stopped:
		case <-time.After(5 * time.Second):
			t.Error("the app did not stop")
		}
	})
	return h
}

func (h *harness) call(method, path, body string, hdr ...string) (int, http.Header, string) {
	h.t.Helper()
	req, _ := http.NewRequest(method, fmt.Sprintf("http://127.0.0.1:%d%s", h.port, path), strings.NewReader(body))
	req.Header.Set("Origin", origin)
	req.Header.Set("X-Datafy-Nonce", nonce)
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, string(b)
}

func (h *harness) state() map[string]any {
	_, _, b := h.call("GET", "/v1/state", "")
	var m map[string]any
	_ = json.Unmarshal([]byte(b), &m)
	return m
}

func (h *harness) waitState(what string, cond func(map[string]any) bool) map[string]any {
	h.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if s := h.state(); cond(s) {
			return s
		}
		time.Sleep(10 * time.Millisecond)
	}
	h.t.Fatalf("timed out waiting for: %s (last state %v)", what, h.state())
	return nil
}

func TestTheWholeFlowEndToEnd(t *testing.T) {
	h := start(t, nil)

	// The page finds the app and learns it owns the session.
	_, _, body := h.call("GET", "/v1/health", "")
	if !strings.Contains(body, `"sessionMatch":true`) || !strings.Contains(body, `"version":"9.9.9"`) {
		t.Fatalf("health: %s", body)
	}
	// It reads the person's SSO profiles so they don't have to type a start URL.
	_, _, body = h.call("GET", "/v1/profiles", "")
	if !strings.Contains(body, `"name":"management"`) {
		t.Fatalf("profiles: %s", body)
	}

	// Connect: sign in. The AWS page opens and the page shows the code to confirm.
	if status, _, b := h.call("POST", "/v1/signin", `{"startUrl":"https://d-1.awsapps.com/start","region":"us-east-1"}`); status != 202 {
		t.Fatalf("signin: %d %s", status, b)
	}
	s := h.waitState("the sign-in prompt", func(s map[string]any) bool { return s["phase"] == "signing_in" && s["prompt"] != nil })
	if p := s["prompt"].(map[string]any); p["userCode"] != "ABCD-EFGH" {
		t.Fatalf("prompt: %v", p)
	}
	h.waitState("the AWS page to be opened", func(map[string]any) bool { h.mu.Lock(); defer h.mu.Unlock(); return len(h.opened) == 1 })
	if h.opened[0] != "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH" {
		t.Fatalf("opened %v", h.opened)
	}
	if h.idc.StartURLs[0] != "https://d-1.awsapps.com/start" {
		t.Fatalf("start URL: %v", h.idc.StartURLs)
	}

	// The person approves in the browser; two accounts, so they choose.
	h.idc.Approve()
	s = h.waitState("choosing", func(s map[string]any) bool { return s["phase"] == "choosing" })
	if len(s["accounts"].([]any)) != 2 {
		t.Fatalf("accounts: %v", s["accounts"])
	}
	if _, _, b := h.call("GET", "/v1/accounts/"+acct1+"/roles", ""); !strings.Contains(b, `"Admin"`) || !strings.Contains(b, `"ReadOnly"`) {
		t.Fatalf("roles: %s", b)
	}
	if status, _, b := h.call("POST", "/v1/select", fmt.Sprintf(`{"accountId":%q,"role":"ReadOnly"}`, acct1)); status != 202 {
		t.Fatalf("select: %d %s", status, b)
	}

	// Scanning starts by itself, and repeats.
	h.waitState("a scan", func(s map[string]any) bool { return s["scan"] != nil })
	h.waitState("several fresh credential fetches", func(map[string]any) bool { return h.idc.CredentialCalls() >= 3 })

	status, hdr, scan := h.call("GET", "/v1/scan", "")
	if status != 200 || scan != scanFile || hdr.Get("ETag") == "" || hdr.Get("X-Scan-Finished-At") != "2026-01-01T00:00:00Z" {
		t.Fatalf("scan: %d %v %q", status, hdr, scan)
	}
	if status, _, _ := h.call("GET", "/v1/scan", "", "If-None-Match", hdr.Get("ETag")); status != 304 {
		t.Fatalf("an unchanged scan must not be sent again: %d", status)
	}

	// The scanner ran as exactly the account and role the person chose, with the credentials from the portal and a
	// clean environment.
	env, _ := os.ReadFile(h.envOut)
	if !strings.Contains(string(env), "AWS_ACCESS_KEY_ID=ASIAFAKE") || strings.Contains(string(env), "AWS_PROFILE") {
		t.Fatalf("scanner environment:\n%s", env)
	}

	// Nothing the page can read contains a secret.
	for _, path := range []string{"/v1/state", "/v1/profiles", "/v1/health"} {
		_, _, b := h.call("GET", path, "")
		for _, secret := range []string{"fakesecretaccesskey", "fakesessiontoken", "bearer-token", "ASIAFAKE", nonce} {
			if strings.Contains(b, secret) {
				t.Fatalf("%s leaked %q: %s", path, secret, b)
			}
		}
	}

	// Quit from the page stops the app.
	if status, _, _ := h.call("POST", "/v1/quit", ""); status != 202 {
		t.Fatalf("quit: %d", status)
	}
	select {
	case <-h.stopped:
		if h.err != nil {
			t.Fatalf("Run returned %v", h.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the app did not stop after quit")
	}
}

func TestAnExpiredSignInIsReportedAndTheLastScanSurvives(t *testing.T) {
	h := start(t, nil)
	h.idc.Accounts = h.idc.Accounts[:1]
	h.idc.Roles = map[string][]string{acct1: {"Admin"}}
	h.idc.Approve()
	h.call("POST", "/v1/signin", `{"startUrl":"https://d-1.awsapps.com/start","region":"us-east-1"}`)
	h.waitState("a scan", func(s map[string]any) bool { return s["scan"] != nil })

	h.idc.Revoke() // AWS now rejects the sign-in
	s := h.waitState("needs sign-in", func(s map[string]any) bool { return s["phase"] == "needs_signin" })
	if p := s["problem"].(map[string]any); p["code"] != "sso_expired" {
		t.Fatalf("%v", p)
	}
	if status, _, b := h.call("GET", "/v1/scan", ""); status != 200 || b != scanFile {
		t.Fatalf("the last scan must still be served: %d", status)
	}
}

func TestASecondLaunchHandsOverToTheRunningApp(t *testing.T) {
	h := start(t, nil)
	newNonce := "second-launch-secret-9876"
	if err := Run(context.Background(), Config{Port: h.port, Allowed: allowed}, link(origin, newNonce)); err != nil {
		t.Fatalf("a second launch must succeed by forwarding: %v", err)
	}
	if status, _, _ := h.call("GET", "/v1/state", ""); status != 403 {
		t.Fatalf("the old secret must stop working: %d", status)
	}
	if status, _, _ := h.call("GET", "/v1/state", "", "X-Datafy-Nonce", newNonce); status != 200 {
		t.Fatalf("the new secret must work: %d", status)
	}
}

func TestAnInvalidLinkStartsNothing(t *testing.T) {
	for _, bad := range []string{"", "https://example.com", link("https://evil.example.com", nonce), link(origin, "short"), "datafy-discovery://open"} {
		err := Run(context.Background(), Config{Port: 0, Allowed: allowed}, bad)
		if !errors.Is(err, protocol.ErrInvalid) {
			t.Errorf("%q: %v", bad, err)
		}
	}
}

func TestAnotherProgramOnThePortIsNotMistakenForTheApp(t *testing.T) {
	other := httptest.NewServer(http.NotFoundHandler())
	defer other.Close()
	port := other.Listener.Addr().(*net.TCPAddr).Port
	if err := Run(context.Background(), Config{Port: port, Allowed: allowed}, link(origin, nonce)); !errors.Is(err, ErrNotOurs) {
		t.Fatalf("got %v", err)
	}
}

func TestTheAppStopsWhenIdleAndStaysWhileUsed(t *testing.T) {
	h := start(t, func(c *Config) { c.IdleLimit = 250 * time.Millisecond })
	for i := 0; i < 8; i++ { // 8 x 60ms = ~480ms of use, longer than the idle limit
		if status, _, _ := h.call("GET", "/v1/state", ""); status != 200 {
			t.Fatalf("the app stopped while in use: %d", status)
		}
		time.Sleep(60 * time.Millisecond)
	}
	select {
	case <-h.stopped:
		if h.err != nil {
			t.Fatal(h.err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the app did not stop after being idle")
	}
}

func TestTheAppStopsWhenAskedToByItsParent(t *testing.T) {
	h := start(t, nil)
	h.cancel()
	select {
	case <-h.stopped:
		if h.err != nil {
			t.Fatal(h.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("did not stop")
	}
	if _, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/v1/health", h.port)); err == nil {
		t.Fatal("the port must be closed after the app stops")
	}
}

func TestTheAppListensOnLoopbackOnly(t *testing.T) {
	h := start(t, nil)
	conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", h.port))
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	// Not reachable by any non-loopback address of this machine.
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		ip, _, _ := net.ParseCIDR(a.String())
		if ip == nil || ip.IsLoopback() || ip.To4() == nil {
			continue
		}
		if c, err := net.DialTimeout("tcp", net.JoinHostPort(ip.String(), fmt.Sprint(h.port)), 300*time.Millisecond); err == nil {
			c.Close()
			t.Fatalf("the app must not be reachable on %s", ip)
		}
	}
}
