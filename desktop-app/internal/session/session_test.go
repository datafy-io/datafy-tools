package session

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/aws/smithy-go"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/scanner"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/sso"
)

// --- fakes ---------------------------------------------------------------------------------------------------------

type fakeSSO struct {
	mu          sync.Mutex
	signInErr   error
	signInHold  chan struct{} // if set, SignIn blocks until closed (or ctx is cancelled)
	accounts    []sso.Account
	roles       map[string][]string
	credsErr    error
	credsCalls  int
	signInCalls int
}

func (f *fakeSSO) SignIn(ctx context.Context, startURL string, onPrompt func(sso.Prompt) error) (sso.Token, error) {
	f.mu.Lock()
	f.signInCalls++
	hold, err := f.signInHold, f.signInErr
	f.mu.Unlock()
	_ = onPrompt(sso.Prompt{URL: "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH", UserCode: "ABCD-EFGH"})
	if hold != nil {
		select {
		case <-hold:
		case <-ctx.Done():
			return sso.Token{}, ctx.Err()
		}
	}
	if err != nil {
		return sso.Token{}, err
	}
	return sso.Token{AccessToken: "SECRET-BEARER-TOKEN"}, nil
}
func (f *fakeSSO) Accounts(context.Context, sso.Token) ([]sso.Account, error) { return f.accounts, nil }
func (f *fakeSSO) Roles(_ context.Context, _ sso.Token, id string) ([]string, error) {
	return f.roles[id], nil
}
func (f *fakeSSO) RoleCredentials(_ context.Context, _ sso.Token, id, role string) (sso.Credentials, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.credsCalls++
	if f.credsErr != nil {
		return sso.Credentials{}, f.credsErr
	}
	return sso.Credentials{AccessKeyID: fmt.Sprintf("ASIA-%s-%s-%d", id, role, f.credsCalls), SecretAccessKey: "SECRET-KEY-VALUE", SessionToken: "SECRET-SESSION"}, nil
}
func (f *fakeSSO) setCredsErr(e error) { f.mu.Lock(); f.credsErr = e; f.mu.Unlock() }
func (f *fakeSSO) calls() int          { f.mu.Lock(); defer f.mu.Unlock(); return f.credsCalls }

type fakeRunner struct {
	mu     sync.Mutex
	n      int
	err    error
	delay  time.Duration
	seen   []string
	starts []time.Time
}

func (r *fakeRunner) Run(ctx context.Context, c sso.Credentials) (scanner.Scan, error) {
	r.mu.Lock()
	r.n++
	n, err, delay := r.n, r.err, r.delay
	r.seen = append(r.seen, c.AccessKeyID)
	r.starts = append(r.starts, time.Now())
	r.mu.Unlock()
	if delay > 0 {
		select {
		case <-time.After(delay):
		case <-ctx.Done():
			return scanner.Scan{}, ctx.Err()
		}
	}
	if err != nil {
		return scanner.Scan{}, err
	}
	return scanner.Scan{
		Data: []byte(fmt.Sprintf(`{"record_type":"summary","scan":%d}`, n) + "\n"), ID: fmt.Sprintf("scan-%d", n),
		FinishedAt: time.Unix(1_800_000_000+int64(n), 0).UTC(), Summary: scanner.Summary{ToolVersion: "0.2.1", AccountsTotal: 3, AccountsScanned: 3},
	}, nil
}
func (r *fakeRunner) setErr(e error) { r.mu.Lock(); r.err = e; r.mu.Unlock() }
func (r *fakeRunner) runs() int      { r.mu.Lock(); defer r.mu.Unlock(); return r.n }

const (
	start  = "https://d-1.awsapps.com/start"
	acct   = "123456789012"
	acct2  = "210987654321"
	region = "us-east-1"
)

func newSession(t *testing.T, f *fakeSSO, r *fakeRunner, mod func(*Options)) (*Session, *[]string) {
	var opened []string
	var mu sync.Mutex
	o := Options{
		NewSSO:   func(string) SSO { return f },
		Runner:   r,
		OpenURL:  func(u string) error { mu.Lock(); opened = append(opened, u); mu.Unlock(); return nil },
		Interval: 40 * time.Millisecond,
		MinGap:   5 * time.Millisecond,
	}
	if mod != nil {
		mod(&o)
	}
	s := New(o)
	t.Cleanup(s.Close)
	return s, &opened
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for: %s", what)
}

func phaseIs(s *Session, p Phase) func() bool { return func() bool { return s.State().Phase == p } }

// --- tests ---------------------------------------------------------------------------------------------------------

func TestSignInThenScanWithAFreshSetOfCredentialsEveryTime(t *testing.T) {
	f := &fakeSSO{accounts: []sso.Account{{ID: acct, Name: "mgmt"}}, roles: map[string][]string{acct: {"Admin"}}}
	r := &fakeRunner{}
	s, opened := newSession(t, f, r, nil)

	if err := s.SignIn(SignInParams{StartURL: start, Region: region}); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "first scan", func() bool { _, ok := s.Latest(); return ok })
	waitFor(t, "three scans", func() bool { return r.runs() >= 3 })

	if len(*opened) != 1 || (*opened)[0] != "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH" {
		t.Fatalf("the AWS sign-in page should open once: %v", *opened)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.seen[0] == r.seen[1] || r.seen[1] == r.seen[2] {
		t.Fatalf("every scan needs its own fresh credentials: %v", r.seen)
	}
	if !strings.HasPrefix(r.seen[0], "ASIA-"+acct+"-Admin-") {
		t.Fatalf("scanned as the wrong account/role: %v", r.seen[0])
	}
}

func TestThePromptIsShownWhileWaitingAndRemovedAfterwards(t *testing.T) {
	hold := make(chan struct{})
	f := &fakeSSO{signInHold: hold, accounts: []sso.Account{{ID: acct}}, roles: map[string][]string{acct: {"Admin"}}}
	s, _ := newSession(t, f, &fakeRunner{}, nil)
	_ = s.SignIn(SignInParams{StartURL: start, Region: region})
	waitFor(t, "prompt", func() bool { return s.State().Prompt != nil })
	v := s.State()
	if v.Phase != SigningIn || v.Prompt.UserCode != "ABCD-EFGH" || !strings.Contains(v.Prompt.URL, "user_code=ABCD-EFGH") {
		t.Fatalf("%+v", v)
	}
	close(hold)
	waitFor(t, "scanning", func() bool { return s.State().Prompt == nil && s.State().Phase != SigningIn })
}

func TestManyAccountsMeansThePersonChoosesAccountAndRole(t *testing.T) {
	f := &fakeSSO{accounts: []sso.Account{{ID: acct, Name: "a"}, {ID: acct2, Name: "b"}}, roles: map[string][]string{acct: {"Admin", "ReadOnly"}, acct2: {"Admin"}}}
	r := &fakeRunner{}
	s, _ := newSession(t, f, r, nil)
	_ = s.SignIn(SignInParams{StartURL: start, Region: region})
	waitFor(t, "choosing", phaseIs(s, Choosing))
	if len(s.State().Accounts) != 2 || r.runs() != 0 {
		t.Fatalf("nothing may be scanned before a choice is made: %+v, runs=%d", s.State(), r.runs())
	}
	roles, err := s.Roles(acct)
	if err != nil || len(roles) != 2 {
		t.Fatalf("%v %v", roles, err)
	}
	if err := s.Select(acct, "ReadOnly"); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "scan", func() bool { return r.runs() > 0 })
	if sel := s.State().Selected; sel == nil || sel.AccountID != acct || sel.Role != "ReadOnly" {
		t.Fatalf("%+v", sel)
	}
}

func TestAnAccountAndRoleFromAProfileSkipsTheChoice(t *testing.T) {
	f := &fakeSSO{accounts: []sso.Account{{ID: acct}, {ID: acct2}}, roles: map[string][]string{}}
	r := &fakeRunner{}
	s, _ := newSession(t, f, r, nil)
	_ = s.SignIn(SignInParams{StartURL: start, Region: region, AccountID: acct2, Role: "Admin"})
	waitFor(t, "scan", func() bool { return r.runs() > 0 })
	if s.State().Phase == Choosing {
		t.Fatal("must not ask")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if !strings.HasPrefix(r.seen[0], "ASIA-"+acct2+"-Admin") {
		t.Fatalf("%v", r.seen)
	}
}

func TestSignInOutcomesAreExplainedInPlainLanguage(t *testing.T) {
	cases := map[string]struct {
		err  error
		code string
	}{
		"declined": {sso.ErrDenied, "signin_declined"},
		"timeout":  {sso.ErrTimedOut, "signin_timeout"},
		"other":    {errors.New("dial tcp: no route to host"), "signin_failed"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			f := &fakeSSO{signInErr: tc.err}
			s, _ := newSession(t, f, &fakeRunner{}, nil)
			_ = s.SignIn(SignInParams{StartURL: start, Region: region})
			waitFor(t, "failure", phaseIs(s, Failed))
			p := s.State().Problem
			if p == nil || p.Code != tc.code || p.Message == "" {
				t.Fatalf("%+v", p)
			}
		})
	}
}

func TestAnExpiredSignInKeepsTheLastScanAndAsksToSignInAgain(t *testing.T) {
	f := &fakeSSO{accounts: []sso.Account{{ID: acct}}, roles: map[string][]string{acct: {"Admin"}}}
	r := &fakeRunner{}
	s, _ := newSession(t, f, r, nil)
	_ = s.SignIn(SignInParams{StartURL: start, Region: region})
	waitFor(t, "a scan", func() bool { _, ok := s.Latest(); return ok })

	f.setCredsErr(sso.ErrExpired)
	waitFor(t, "needs sign-in", phaseIs(s, NeedsSignIn))
	v := s.State()
	if v.Problem == nil || v.Problem.Code != "sso_expired" {
		t.Fatalf("%+v", v.Problem)
	}
	if _, ok := s.Latest(); !ok || v.Scan == nil {
		t.Fatal("the last complete scan must stay available")
	}
	runs := r.runs()
	time.Sleep(150 * time.Millisecond)
	if r.runs() != runs {
		t.Fatal("scanning must stop until the person signs in again")
	}

	f.setCredsErr(nil) // they sign in again
	_ = s.SignIn(SignInParams{StartURL: start, Region: region})
	waitFor(t, "scanning again", func() bool { return r.runs() > runs })
	waitFor(t, "problem cleared", func() bool { return s.State().Problem == nil })
}

func TestAFailedScanNeverReplacesTheLastGoodOne(t *testing.T) {
	f := &fakeSSO{accounts: []sso.Account{{ID: acct}}, roles: map[string][]string{acct: {"Admin"}}}
	r := &fakeRunner{}
	s, _ := newSession(t, f, r, nil)
	_ = s.SignIn(SignInParams{StartURL: start, Region: region})
	waitFor(t, "a scan", func() bool { _, ok := s.Latest(); return ok })
	good, _ := s.Latest()

	r.setErr(errors.New("boom: " + "SECRET-KEY-VALUE"))
	waitFor(t, "problem", func() bool { p := s.State().Problem; return p != nil && p.Code == "scan_failed" })
	if still, _ := s.Latest(); still.ID < good.ID {
		t.Fatalf("a failure must not roll the scan back: %s < %s", still.ID, good.ID)
	}
	if strings.Contains(s.State().Problem.Message, "SECRET") {
		t.Fatal("the problem shown to the page must not carry the scanner's raw error")
	}

	r.setErr(nil)
	waitFor(t, "recovered", func() bool { return s.State().Problem == nil })
	if latest, _ := s.Latest(); latest.ID == good.ID {
		t.Fatal("a later good scan should replace the old one")
	}
}

func TestCredentialErrorsAreRetriedNotFatal(t *testing.T) {
	f := &fakeSSO{accounts: []sso.Account{{ID: acct}}, roles: map[string][]string{acct: {"Admin"}}}
	f.credsErr = errors.New("network is down")
	r := &fakeRunner{}
	s, _ := newSession(t, f, r, nil)
	_ = s.SignIn(SignInParams{StartURL: start, Region: region})
	waitFor(t, "problem", func() bool { p := s.State().Problem; return p != nil && p.Code == "credentials_failed" })
	f.setCredsErr(nil)
	waitFor(t, "recovery", func() bool { _, ok := s.Latest(); return ok })
	if s.State().Problem != nil {
		waitFor(t, "problem cleared", func() bool { return s.State().Problem == nil })
	}
}

func TestScansAreSpacedAndNeverOverlap(t *testing.T) {
	f := &fakeSSO{accounts: []sso.Account{{ID: acct}}, roles: map[string][]string{acct: {"Admin"}}}
	var active, peak int32
	r := &fakeRunner{delay: 100 * time.Millisecond} // slower than the 40ms interval
	s, _ := newSession(t, f, r, func(o *Options) {
		o.Runner = runnerFunc(func(ctx context.Context, c sso.Credentials) (scanner.Scan, error) {
			n := atomic.AddInt32(&active, 1)
			for {
				p := atomic.LoadInt32(&peak)
				if n <= p || atomic.CompareAndSwapInt32(&peak, p, n) {
					break
				}
			}
			defer atomic.AddInt32(&active, -1)
			return r.Run(ctx, c)
		})
		o.MinGap = 20 * time.Millisecond
	})
	_ = s.SignIn(SignInParams{StartURL: start, Region: region})
	waitFor(t, "three scans", func() bool { return r.runs() >= 3 })
	if peak != 1 {
		t.Fatalf("scans overlapped (peak %d)", peak)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if gap := r.starts[1].Sub(r.starts[0]); gap < 115*time.Millisecond {
		t.Fatalf("after a scan that overran the interval the next must wait the minimum gap: only %s between starts", gap)
	}
}

type runnerFunc func(ctx context.Context, c sso.Credentials) (scanner.Scan, error)

func (f runnerFunc) Run(ctx context.Context, c sso.Credentials) (scanner.Scan, error) {
	return f(ctx, c)
}

func TestScanNowSkipsTheWait(t *testing.T) {
	f := &fakeSSO{accounts: []sso.Account{{ID: acct}}, roles: map[string][]string{acct: {"Admin"}}}
	r := &fakeRunner{}
	s, _ := newSession(t, f, r, func(o *Options) { o.Interval = time.Hour; o.MinGap = time.Millisecond })
	_ = s.SignIn(SignInParams{StartURL: start, Region: region})
	waitFor(t, "first scan and waiting", func() bool { return r.runs() == 1 && s.State().Phase == Waiting })
	s.ScanNow()
	waitFor(t, "a second scan long before the hour is up", func() bool { return r.runs() == 2 })
}

func TestSignOutStopsEverythingAndForgetsTheScan(t *testing.T) {
	f := &fakeSSO{accounts: []sso.Account{{ID: acct}}, roles: map[string][]string{acct: {"Admin"}}}
	r := &fakeRunner{}
	s, _ := newSession(t, f, r, nil)
	_ = s.SignIn(SignInParams{StartURL: start, Region: region})
	waitFor(t, "a scan", func() bool { _, ok := s.Latest(); return ok })
	s.SignOut()
	runs := r.runs()
	time.Sleep(120 * time.Millisecond)
	if r.runs() != runs {
		t.Fatal("no scan may run after signing out")
	}
	if _, ok := s.Latest(); ok || s.State().Phase != Idle || s.State().Selected != nil {
		t.Fatalf("%+v", s.State())
	}
	if _, err := s.Roles(acct); err == nil {
		t.Fatal("the sign-in must be forgotten")
	}
}

func TestSigningInAgainReplacesTheRunningLoop(t *testing.T) {
	f := &fakeSSO{accounts: []sso.Account{{ID: acct}}, roles: map[string][]string{acct: {"Admin"}}}
	var active, peak int32
	r := &fakeRunner{}
	s, _ := newSession(t, f, r, func(o *Options) {
		o.Runner = runnerFunc(func(ctx context.Context, c sso.Credentials) (scanner.Scan, error) {
			n := atomic.AddInt32(&active, 1)
			if n > atomic.LoadInt32(&peak) {
				atomic.StoreInt32(&peak, n)
			}
			defer atomic.AddInt32(&active, -1)
			return r.Run(ctx, c)
		})
		o.Interval = 10 * time.Millisecond
	})
	for i := 0; i < 5; i++ {
		_ = s.SignIn(SignInParams{StartURL: start, Region: region})
		time.Sleep(25 * time.Millisecond)
	}
	waitFor(t, "scans", func() bool { return r.runs() >= 3 })
	if peak > 1 {
		t.Fatalf("several loops ran at once (peak %d)", peak)
	}
}

func TestInputFromTheWebPageIsValidated(t *testing.T) {
	f := &fakeSSO{}
	s, _ := newSession(t, f, &fakeRunner{}, nil)
	bad := []SignInParams{
		{StartURL: "http://d-1.awsapps.com/start", Region: region},
		{StartURL: "https://evil.example.com/start", Region: region},
		{StartURL: "https://d-1.awsapps.com.evil.io/start", Region: region},
		{StartURL: "https://u:p@d-1.awsapps.com/start", Region: region},
		{StartURL: "https://d-1.awsapps.com/start?x=1", Region: region},
		{StartURL: "https://d-1.awsapps.com/other", Region: region},
		{StartURL: "javascript:alert(1)", Region: region},
		{StartURL: start, Region: "us-east-1; rm -rf /"},
		{StartURL: start, Region: ""},
		{StartURL: start, Region: region, AccountID: "12345", Role: "Admin"},
		{StartURL: start, Region: region, AccountID: acct, Role: "Admin; rm"},
		{StartURL: start, Region: region, AccountID: acct},
	}
	for _, p := range bad {
		if err := s.SignIn(p); !errors.Is(err, ErrBadInput) {
			t.Errorf("%+v should be refused, got %v", p, err)
		}
	}
	if f.signInCalls != 0 {
		t.Fatal("nothing may reach AWS for refused input")
	}
	if err := s.Select("nope", "Admin"); !errors.Is(err, ErrBadInput) {
		t.Errorf("%v", err)
	}
	if err := s.Select(acct, "Admin"); err == nil {
		t.Error("selecting before signing in must fail")
	}
	if got, err := NormalizeStartURL("https://d-1.awsapps.com/start/#/"); err != nil || got != start {
		t.Errorf("a trailing slash and fragment are fine: %q %v", got, err)
	}
}

func TestNothingSecretEverAppearsInTheState(t *testing.T) {
	f := &fakeSSO{accounts: []sso.Account{{ID: acct}}, roles: map[string][]string{acct: {"Admin"}}}
	r := &fakeRunner{}
	s, _ := newSession(t, f, r, nil)
	_ = s.SignIn(SignInParams{StartURL: start, Region: region})
	waitFor(t, "a scan", func() bool { _, ok := s.Latest(); return ok })
	f.setCredsErr(errors.New("denied for SECRET-KEY-VALUE"))
	waitFor(t, "problem", func() bool { return s.State().Problem != nil })
	b, _ := json.Marshal(s.State())
	for _, secret := range []string{"SECRET-BEARER-TOKEN", "SECRET-KEY-VALUE", "SECRET-SESSION", "ASIA-"} {
		if strings.Contains(string(b), secret) {
			t.Fatalf("%q leaked into the state the page sees: %s", secret, b)
		}
	}
}

func TestCloseStopsEveryGoroutine(t *testing.T) {
	f := &fakeSSO{accounts: []sso.Account{{ID: acct}}, roles: map[string][]string{acct: {"Admin"}}}
	r := &fakeRunner{delay: 20 * time.Millisecond}
	s := New(Options{NewSSO: func(string) SSO { return f }, Runner: r, Interval: 5 * time.Millisecond, MinGap: time.Millisecond})
	_ = s.SignIn(SignInParams{StartURL: start, Region: region})
	waitFor(t, "scanning", func() bool { return r.runs() >= 1 })
	done := make(chan struct{})
	go func() { s.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("Close must not hang")
	}
	if err := s.SignIn(SignInParams{StartURL: start, Region: region}); err == nil {
		t.Fatal("a closed session must refuse new work")
	}
}

func TestOnlySafeLabelsReachThePage(t *testing.T) {
	apiErr := &smithy.GenericAPIError{Code: "ThrottlingException", Message: "Rate exceeded for SECRET-KEY-VALUE"}
	cases := map[string]struct {
		err  error
		want string
	}{
		"an AWS error shows only its code": {apiErr, "ThrottlingException"},
		"a wrapped AWS error":              {fmt.Errorf("calling AWS: %w", apiErr), "ThrottlingException"},
		"a code that is not a plain code":  {&smithy.GenericAPIError{Code: "Bad code; with SECRET", Message: "m"}, "an unexpected error"},
		"a timeout":                        {context.DeadlineExceeded, "timed out"},
		"plain text with a secret":         {errors.New("denied for SECRET-KEY-VALUE"), "an unexpected error"},
	}
	for name, tc := range cases {
		if got := describe(tc.err); got != tc.want || strings.Contains(got, "SECRET") {
			t.Errorf("%s: got %q, want %q", name, got, tc.want)
		}
	}
}
