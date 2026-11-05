package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/datafy-io/datafy-tools/desktop-app/internal/protocol"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/scanner"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/session"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/sso"
)

const (
	origin = "https://app.example.com"
	other  = "https://other.example.com" // allowed by the build, but not the page that launched the app
	evil   = "https://evil.example.org"  // not allowed at all
	nonce  = "launch-secret-0123456789"
)

type fakeSession struct {
	mu    sync.Mutex
	calls []string
	scan  *scanner.Scan
	err   error
	view  session.View
}

func (f *fakeSession) rec(s string) { f.mu.Lock(); f.calls = append(f.calls, s); f.mu.Unlock() }
func (f *fakeSession) State() session.View {
	f.rec("State")
	return f.view
}
func (f *fakeSession) Latest() (scanner.Scan, bool) {
	f.rec("Latest")
	if f.scan == nil {
		return scanner.Scan{}, false
	}
	return *f.scan, true
}
func (f *fakeSession) SignIn(p session.SignInParams) error {
	f.rec(fmt.Sprintf("SignIn %s %s %s %s", p.StartURL, p.Region, p.AccountID, p.Role))
	return f.err
}
func (f *fakeSession) Roles(id string) ([]string, error) {
	f.rec("Roles " + id)
	if !session.ValidAccountID(id) {
		return nil, session.ErrBadInput
	}
	return []string{"Admin"}, f.err
}
func (f *fakeSession) Select(a, r string) error { f.rec("Select " + a + " " + r); return f.err }
func (f *fakeSession) ScanNow()                 { f.rec("ScanNow") }
func (f *fakeSession) SignOut()                 { f.rec("SignOut") }
func (f *fakeSession) called() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

type env struct {
	srv    *httptest.Server
	api    *Server
	sess   *fakeSession
	log    *[]string
	quit   chan struct{}
	port   int
	client *http.Client
}

func setup(t *testing.T) *env {
	sess := &fakeSession{}
	var logs []string
	var mu sync.Mutex
	quit := make(chan struct{}, 1)
	ts := httptest.NewUnstartedServer(nil)
	port := ts.Listener.Addr().(*net.TCPAddr).Port
	a := New(Deps{
		Session: sess,
		Profiles: func() ([]sso.Profile, error) {
			return []sso.Profile{{Name: "management", StartURL: "https://d-1.awsapps.com/start", Region: "us-east-1"}}, nil
		},
		Allowed: func(o string) bool { return o == origin || o == other },
		Port:    port, Version: "9.9.9",
		Quit: func() { quit <- struct{}{} },
		Log:  func(f string, args ...any) { mu.Lock(); logs = append(logs, fmt.Sprintf(f, args...)); mu.Unlock() },
	})
	ts.Config.Handler = a.Handler()
	ts.Start()
	t.Cleanup(ts.Close)
	a.Bind(protocol.Launch{Origin: origin, Nonce: nonce})
	return &env{srv: ts, api: a, sess: sess, log: &logs, quit: quit, port: port, client: &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}

type req struct {
	method, path, body string
	origin             string
	noOrigin           bool
	host               string
	nonce              string
	noNonce            bool
	headers            map[string]string
}

func (e *env) do(t *testing.T, r req) (int, http.Header, string) {
	var body io.Reader
	if r.body != "" {
		body = strings.NewReader(r.body)
	}
	hr, err := http.NewRequest(r.method, e.srv.URL+r.path, body)
	if err != nil {
		t.Fatal(err)
	}
	if !r.noOrigin {
		o := r.origin
		if o == "" {
			o = origin
		}
		hr.Header.Set("Origin", o)
	}
	if !r.noNonce {
		n := r.nonce
		if n == "" {
			n = nonce
		}
		hr.Header.Set("X-Datafy-Nonce", n)
	}
	if r.host != "" {
		hr.Host = r.host
	}
	for k, v := range r.headers {
		hr.Header.Set(k, v)
	}
	resp, err := e.client.Do(hr)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, string(b)
}

// every endpoint that needs the secret
var protected = []req{
	{method: "GET", path: "/v1/state"},
	{method: "GET", path: "/v1/profiles"},
	{method: "POST", path: "/v1/signin", body: `{"startUrl":"https://d-1.awsapps.com/start","region":"us-east-1"}`},
	{method: "GET", path: "/v1/accounts/123456789012/roles"},
	{method: "POST", path: "/v1/select", body: `{"accountId":"123456789012","role":"Admin"}`},
	{method: "POST", path: "/v1/scan/now"},
	{method: "GET", path: "/v1/scan"},
	{method: "POST", path: "/v1/signout"},
	{method: "POST", path: "/v1/quit"},
}

func TestEveryProtectedRouteWorksWithTheRightHostOriginAndSecret(t *testing.T) {
	e := setup(t)
	e.sess.scan = &scanner.Scan{Data: []byte("{}\n"), ID: "abc"}
	for _, r := range protected {
		status, h, body := e.do(t, r)
		if status/100 != 2 {
			t.Errorf("%s %s: %d %s", r.method, r.path, status, body)
		}
		if h.Get("Access-Control-Allow-Origin") != origin {
			t.Errorf("%s %s: CORS must name the exact origin, got %q", r.method, r.path, h.Get("Access-Control-Allow-Origin"))
		}
	}
}

func TestEveryProtectedRouteRefusesAnythingElseAndNeverTouchesTheSession(t *testing.T) {
	cases := map[string]func(r req) req{
		"a Host that is not localhost (DNS rebinding)":  func(r req) req { r.host = "evil.example.com:" + "1"; return r },
		"localhost with the wrong port":                 func(r req) req { r.host = "127.0.0.1:1"; return r },
		"no Origin header":                              func(r req) req { r.noOrigin = true; return r },
		"an origin the build does not allow":            func(r req) req { r.origin = evil; return r },
		"an allowed origin that did not launch the app": func(r req) req { r.origin = other; return r },
		"no secret":                        func(r req) req { r.noNonce = true; return r },
		"the wrong secret":                 func(r req) req { r.nonce = "wrong-secret-0123456789"; return r },
		"a secret that is only a prefix":   func(r req) req { r.nonce = nonce[:len(nonce)-1]; return r },
		"the secret with extra characters": func(r req) req { r.nonce = nonce + "x"; return r },
		"an empty secret": func(r req) req {
			r.nonce = ""
			r.noNonce = false
			r.headers = map[string]string{"X-Datafy-Nonce": ""}
			return r
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			e := setup(t)
			for _, base := range protected {
				r := mutate(base)
				if strings.Contains(name, "Host that is not") {
					r.host = fmt.Sprintf("evil.example.com:%d", e.port)
				}
				status, _, body := e.do(t, r)
				if status != http.StatusForbidden {
					t.Errorf("%s %s: want 403, got %d", base.method, base.path, status)
				}
				if strings.Contains(body, "Admin") || strings.Contains(body, "management") {
					t.Errorf("%s %s: a refused request must learn nothing: %s", base.method, base.path, body)
				}
			}
			if got := e.sess.called(); len(got) != 0 {
				t.Errorf("a refused request must never reach the session, but it saw %v", got)
			}
			select {
			case <-e.quit:
				t.Error("a refused request must not be able to quit the app")
			case <-time.After(20 * time.Millisecond):
			}
		})
	}
}

func TestRefusedOriginsGetNoCORSHeadersAtAll(t *testing.T) {
	e := setup(t)
	_, h, _ := e.do(t, req{method: "GET", path: "/v1/state", origin: evil})
	for k := range h {
		if strings.HasPrefix(strings.ToLower(k), "access-control") {
			t.Errorf("an origin that is not allowed must get no CORS header, got %s", k)
		}
	}
}

func TestHealthTellsAnAllowedPageWhetherItOwnsTheRunningSession(t *testing.T) {
	e := setup(t)
	decode := func(r req) map[string]any {
		status, _, body := e.do(t, r)
		if status != 200 {
			t.Fatalf("%d %s", status, body)
		}
		var m map[string]any
		_ = json.Unmarshal([]byte(body), &m)
		return m
	}
	mine := decode(req{method: "GET", path: "/v1/health"})
	if mine["ok"] != true || mine["sessionMatch"] != true || mine["version"] != "9.9.9" || mine["bound"] != true {
		t.Fatalf("%v", mine)
	}
	if m := decode(req{method: "GET", path: "/v1/health", nonce: "someone-elses-secret-000000"}); m["sessionMatch"] != false || m["bound"] != true {
		t.Fatalf("a stale page must be told its session is not the running one: %v", m)
	}
	if m := decode(req{method: "GET", path: "/v1/health", noNonce: true}); m["sessionMatch"] != false {
		t.Fatalf("%v", m)
	}
	// An origin the build allows but that did not launch the app can see that the app exists, and nothing more.
	if m := decode(req{method: "GET", path: "/v1/health", origin: other}); m["sessionMatch"] != false {
		t.Fatalf("%v", m)
	}
	// Health still demands an allowed origin and a localhost host.
	if status, _, _ := e.do(t, req{method: "GET", path: "/v1/health", origin: evil}); status != 403 {
		t.Fatalf("%d", status)
	}
	if status, _, _ := e.do(t, req{method: "GET", path: "/v1/health", noOrigin: true}); status != 403 {
		t.Fatalf("%d", status)
	}
}

func TestBeforeAnyLaunchNothingIsServedExceptHealth(t *testing.T) {
	e := setup(t)
	e.api.mu.Lock()
	e.api.bound, e.api.origin, e.api.nonce = false, "", ""
	e.api.mu.Unlock()
	status, _, body := e.do(t, req{method: "GET", path: "/v1/state", nonce: ""})
	if status != 403 || !strings.Contains(body, "not_launched") {
		t.Fatalf("%d %s", status, body)
	}
	if status, _, _ := e.do(t, req{method: "GET", path: "/v1/health"}); status != 200 {
		t.Fatalf("%d", status)
	}
}

func TestPreflightForPrivateNetworkAccess(t *testing.T) {
	e := setup(t)
	status, h, _ := e.do(t, req{method: "OPTIONS", path: "/v1/scan", noNonce: true, headers: map[string]string{
		"Access-Control-Request-Method": "GET", "Access-Control-Request-Headers": "x-datafy-nonce, if-none-match", "Access-Control-Request-Private-Network": "true",
	}})
	if status != 204 || h.Get("Access-Control-Allow-Origin") != origin || h.Get("Access-Control-Allow-Private-Network") != "true" {
		t.Fatalf("%d %v", status, h)
	}
	for _, want := range []string{"x-datafy-nonce", "if-none-match", "content-type"} {
		if !strings.Contains(h.Get("Access-Control-Allow-Headers"), want) {
			t.Errorf("must allow the %s header, got %q", want, h.Get("Access-Control-Allow-Headers"))
		}
	}
	for _, bad := range []req{
		{method: "OPTIONS", path: "/v1/scan", origin: evil, noNonce: true},
		{method: "OPTIONS", path: "/v1/scan", noOrigin: true, noNonce: true},
		{method: "OPTIONS", path: "/v1/scan", noNonce: true, host: fmt.Sprintf("evil.example.com:%d", e.port)},
	} {
		if status, _, _ := e.do(t, bad); status != 403 {
			t.Errorf("%+v: %d", bad, status)
		}
	}
}

func TestInternalOpenIsForTheSecondLaunchAndNeverForABrowser(t *testing.T) {
	e := setup(t)
	body := fmt.Sprintf(`{"origin":%q,"nonce":"second-launch-secret-0123"}`, origin)

	for name, r := range map[string]req{
		"a request from a web page (it always has an Origin)": {method: "POST", path: "/internal/open", body: body, noNonce: true},
		"a rebinding host":                {method: "POST", path: "/internal/open", body: body, noOrigin: true, noNonce: true, host: fmt.Sprintf("evil.example.com:%d", e.port)},
		"a disallowed origin in the body": {method: "POST", path: "/internal/open", body: fmt.Sprintf(`{"origin":%q,"nonce":"second-launch-secret-0123"}`, evil), noOrigin: true, noNonce: true},
		"a short secret":                  {method: "POST", path: "/internal/open", body: fmt.Sprintf(`{"origin":%q,"nonce":"short"}`, origin), noOrigin: true, noNonce: true},
		"an origin with a path":           {method: "POST", path: "/internal/open", body: fmt.Sprintf(`{"origin":%q,"nonce":"second-launch-secret-0123"}`, origin+"/x"), noOrigin: true, noNonce: true},
		"an extra field":                  {method: "POST", path: "/internal/open", body: fmt.Sprintf(`{"origin":%q,"nonce":"second-launch-secret-0123","x":1}`, origin), noOrigin: true, noNonce: true},
	} {
		if status, _, _ := e.do(t, r); status != 403 && status != 400 {
			t.Errorf("%s: %d", name, status)
		}
	}
	if status, _, _ := e.do(t, req{method: "GET", path: "/v1/state"}); status != 200 {
		t.Fatalf("none of those may have changed the session: %d", status)
	}
	if status, _, _ := e.do(t, req{method: "GET", path: "/internal/open", noOrigin: true, noNonce: true}); status != 405 && status != 404 {
		t.Errorf("GET: %d", status)
	}

	// The genuine second launch (no Origin header) replaces the session, and the old secret stops working.
	if status, _, b := e.do(t, req{method: "POST", path: "/internal/open", body: body, noOrigin: true, noNonce: true}); status != 204 {
		t.Fatalf("%d %s", status, b)
	}
	if status, _, _ := e.do(t, req{method: "GET", path: "/v1/state"}); status != 403 {
		t.Fatalf("the previous secret must stop working: %d", status)
	}
	if status, _, _ := e.do(t, req{method: "GET", path: "/v1/state", nonce: "second-launch-secret-0123"}); status != 200 {
		t.Fatalf("the new secret must work: %d", status)
	}
}

func TestPOSTBodiesAreStrict(t *testing.T) {
	e := setup(t)
	url := "/v1/signin"
	for name, body := range map[string]string{
		"not JSON":      `hello`,
		"unknown field": `{"startUrl":"https://d-1.awsapps.com/start","region":"us-east-1","cmd":"calc"}`,
		"empty":         ``,
		"an array":      `[1]`,
	} {
		if status, _, _ := e.do(t, req{method: "POST", path: url, body: body, headers: map[string]string{"Content-Type": "application/json"}}); status != 400 {
			t.Errorf("%s: %d", name, status)
		}
	}
	huge := `{"startUrl":"` + strings.Repeat("a", 10_000) + `","region":"us-east-1"}`
	if status, _, _ := e.do(t, req{method: "POST", path: url, body: huge}); status != http.StatusRequestEntityTooLarge {
		t.Errorf("an oversized body must be refused: %d", status)
	}
	if got := e.sess.called(); len(got) != 0 {
		t.Errorf("nothing malformed may reach the session: %v", got)
	}
}

func TestSignInPassesTheParametersAndMapsErrors(t *testing.T) {
	e := setup(t)
	status, _, body := e.do(t, req{method: "POST", path: "/v1/signin", body: `{"startUrl":"https://d-1.awsapps.com/start","region":"eu-west-1","accountId":"123456789012","role":"Admin"}`})
	if status != 202 {
		t.Fatalf("%d %s", status, body)
	}
	if got := e.sess.called(); len(got) != 1 || got[0] != "SignIn https://d-1.awsapps.com/start eu-west-1 123456789012 Admin" {
		t.Fatalf("%v", got)
	}
	e.sess.err = fmt.Errorf("%w: nope", session.ErrBadInput)
	if status, _, b := e.do(t, req{method: "POST", path: "/v1/signin", body: `{"startUrl":"x","region":"y"}`}); status != 400 || !strings.Contains(b, "bad_input") {
		t.Fatalf("%d %s", status, b)
	}
	e.sess.err = errors.New("shutting down")
	if status, _, _ := e.do(t, req{method: "POST", path: "/v1/signin", body: `{"startUrl":"x","region":"y"}`}); status != 409 {
		t.Fatalf("%d", status)
	}
}

func TestRolesRejectsAnythingThatIsNotAnAccountID(t *testing.T) {
	e := setup(t)
	for _, bad := range []string{"abc", "12345", "1234567890123", "..%2F..", "123456789012;ls"} {
		if status, _, _ := e.do(t, req{method: "GET", path: "/v1/accounts/" + bad + "/roles"}); status != 400 && status != 404 {
			t.Errorf("%s: %d", bad, status)
		}
	}
	status, _, body := e.do(t, req{method: "GET", path: "/v1/accounts/123456789012/roles"})
	if status != 200 || !strings.Contains(body, `"roles":["Admin"]`) {
		t.Fatalf("%d %s", status, body)
	}
}

func TestScanIsServedWithAnETagSoTheCostOfPollingIsLow(t *testing.T) {
	e := setup(t)
	if status, _, _ := e.do(t, req{method: "GET", path: "/v1/scan"}); status != 404 {
		t.Fatalf("no scan yet: %d", status)
	}
	e.sess.scan = &scanner.Scan{Data: []byte("{\"record_type\":\"summary\"}\n"), ID: "abc123", FinishedAt: time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)}
	status, h, body := e.do(t, req{method: "GET", path: "/v1/scan"})
	if status != 200 || body != "{\"record_type\":\"summary\"}\n" {
		t.Fatalf("%d %q", status, body)
	}
	if h.Get("ETag") != `"abc123"` || h.Get("X-Scan-Finished-At") != "2026-01-02T03:04:05Z" ||
		h.Get("Content-Type") != "application/x-ndjson" || h.Get("Cache-Control") != "no-store" || h.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("%v", h)
	}
	if !strings.Contains(h.Get("Access-Control-Expose-Headers"), "ETag") {
		t.Fatal("the page must be allowed to read the ETag")
	}
	status, _, body = e.do(t, req{method: "GET", path: "/v1/scan", headers: map[string]string{"If-None-Match": `"abc123"`}})
	if status != 304 || body != "" {
		t.Fatalf("unchanged scans must not be sent again: %d %q", status, body)
	}
	e.sess.scan.ID = "def456"
	if status, _, _ := e.do(t, req{method: "GET", path: "/v1/scan", headers: map[string]string{"If-None-Match": `"abc123"`}}); status != 200 {
		t.Fatalf("a new scan must be sent: %d", status)
	}
}

func TestProfilesNeverCarryKeys(t *testing.T) {
	e := setup(t)
	_, _, body := e.do(t, req{method: "GET", path: "/v1/profiles"})
	var out struct {
		Profiles []map[string]any `json:"profiles"`
	}
	if err := json.Unmarshal([]byte(body), &out); err != nil || len(out.Profiles) != 1 {
		t.Fatalf("%s %v", body, err)
	}
	for k := range out.Profiles[0] {
		if strings.Contains(strings.ToLower(k), "key") || strings.Contains(strings.ToLower(k), "secret") || strings.Contains(strings.ToLower(k), "token") {
			t.Fatalf("unexpected field %s", k)
		}
	}
	e2 := setup(t)
	e2.api.d.Profiles = func() ([]sso.Profile, error) { return nil, errors.New("permission denied") }
	if status, _, b := e2.do(t, req{method: "GET", path: "/v1/profiles"}); status != 200 || !strings.Contains(b, `"profiles":[]`) {
		t.Fatalf("a broken config must give an empty list, not an error: %d %s", status, b)
	}
}

func TestQuitStopsTheAppButOnlyForTheRightPage(t *testing.T) {
	e := setup(t)
	if status, _, _ := e.do(t, req{method: "POST", path: "/v1/quit"}); status != 202 {
		t.Fatalf("%d", status)
	}
	select {
	case <-e.quit:
	case <-time.After(time.Second):
		t.Fatal("Quit was not called")
	}
}

func TestUnknownRoutesAndWrongMethods(t *testing.T) {
	e := setup(t)
	if status, _, _ := e.do(t, req{method: "GET", path: "/nope"}); status != 404 {
		t.Errorf("%d", status)
	}
	for _, r := range []req{{method: "POST", path: "/v1/state"}, {method: "GET", path: "/v1/signin"}, {method: "DELETE", path: "/v1/scan"}, {method: "PUT", path: "/v1/select"}} {
		if status, _, _ := e.do(t, r); status != 405 {
			t.Errorf("%s %s: %d", r.method, r.path, status)
		}
	}
}

func TestTheLogNeverContainsTheSecretOrBodies(t *testing.T) {
	e := setup(t)
	e.do(t, req{method: "GET", path: "/v1/state"})
	e.do(t, req{method: "POST", path: "/v1/signin", body: `{"startUrl":"https://d-1.awsapps.com/start?token=SECRETQUERY","region":"us-east-1"}`})
	e.do(t, req{method: "GET", path: "/v1/state", nonce: "WRONG-SECRET-VALUE-0000"})
	all := strings.Join(*e.log, "\n")
	for _, secret := range []string{nonce, "WRONG-SECRET-VALUE", "SECRETQUERY", "d-1.awsapps.com"} {
		if strings.Contains(all, secret) {
			t.Fatalf("%q must not be logged:\n%s", secret, all)
		}
	}
	if !strings.Contains(all, "GET /v1/state -> 200") || !strings.Contains(all, "-> 403") {
		t.Fatalf("method, path and status should be logged:\n%s", all)
	}
}

func TestResponsesNeverContainSecrets(t *testing.T) {
	e := setup(t)
	e.sess.view = session.View{Phase: session.Waiting, Problem: &session.Problem{Code: "x", Message: "y"}}
	_, _, body := e.do(t, req{method: "GET", path: "/v1/state"})
	for _, secret := range []string{nonce} {
		if strings.Contains(body, secret) {
			t.Fatalf("%q leaked: %s", secret, body)
		}
	}
	var buf bytes.Buffer
	_ = json.NewEncoder(&buf).Encode(e.sess.view)
	if strings.Contains(buf.String(), "accessToken") {
		t.Fatal("the view must not have a token field")
	}
}
