// Package session runs the whole flow: sign in with AWS, choose an account and role, then scan every 30 seconds.
//
// It never holds on to a scan that did not finish: the last COMPLETE scan stays available while a newer one is
// running, fails, or the sign-in has to be renewed. Credentials and the sign-in token stay inside this package.
package session

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/datafy-io/datafy-tools/desktop-app/internal/scanner"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/sso"
)

type Phase string

const (
	Idle        Phase = "idle"         // nothing started
	SigningIn   Phase = "signing_in"   // waiting for the person to finish in the AWS sign-in page
	Choosing    Phase = "choosing"     // signed in; the person must pick an account and role
	Scanning    Phase = "scanning"     // a scan is running
	Waiting     Phase = "waiting"      // between scans
	NeedsSignIn Phase = "needs_signin" // the AWS sign-in expired; the last scan is still available
	Failed      Phase = "failed"       // could not sign in (declined, timed out, or an error)
)

// SSO is what the session needs from AWS Identity Center. *sso.Client satisfies it.
type SSO interface {
	SignIn(ctx context.Context, startURL string, onPrompt func(sso.Prompt) error) (sso.Token, error)
	Accounts(ctx context.Context, tok sso.Token) ([]sso.Account, error)
	Roles(ctx context.Context, tok sso.Token, accountID string) ([]string, error)
	RoleCredentials(ctx context.Context, tok sso.Token, accountID, role string) (sso.Credentials, error)
}

// Options wires the session to the outside world.
type Options struct {
	// NewSSO builds a client for an Identity Center region.
	NewSSO func(region string) SSO
	Runner scanner.Runner
	// OpenURL opens the AWS sign-in page. A failure is not fatal: the page also shows the URL and code.
	OpenURL  func(url string) error
	Interval time.Duration
	MinGap   time.Duration
	Now      func() time.Time
	Log      func(format string, args ...any)
}

// Problem is something the person can read and act on.
type Problem struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type Prompt struct {
	URL      string `json:"url"`
	UserCode string `json:"userCode"`
}

type ScanInfo struct {
	FinishedAt time.Time       `json:"finishedAt"`
	ID         string          `json:"id"`
	Summary    scanner.Summary `json:"summary"`
}

type Selected struct {
	AccountID string `json:"accountId"`
	Role      string `json:"role"`
}

// View is the session's state, safe to send to the page: it contains no credentials and no tokens.
type View struct {
	Phase      Phase         `json:"phase"`
	Prompt     *Prompt       `json:"prompt,omitempty"`
	Accounts   []sso.Account `json:"accounts,omitempty"`
	Selected   *Selected     `json:"selected,omitempty"`
	Scan       *ScanInfo     `json:"scan,omitempty"`
	NextScanAt *time.Time    `json:"nextScanAt,omitempty"`
	Problem    *Problem      `json:"problem,omitempty"`
}

type Session struct {
	o Options

	mu       sync.Mutex
	phase    Phase
	prompt   *Prompt
	accounts []sso.Account
	selected *Selected
	problem  *Problem
	latest   *scanner.Scan
	nextAt   *time.Time

	startURL string
	region   string
	client   SSO
	token    sso.Token

	cancel context.CancelFunc // cancels the sign-in or the scan loop in progress
	nudge  chan struct{}
	wg     sync.WaitGroup
	closed bool
}

func New(o Options) *Session {
	if o.Interval == 0 {
		o.Interval = 30 * time.Second
	}
	if o.MinGap == 0 {
		o.MinGap = 5 * time.Second
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Log == nil {
		o.Log = func(string, ...any) {}
	}
	if o.OpenURL == nil {
		o.OpenURL = func(string) error { return nil }
	}
	return &Session{o: o, phase: Idle, nudge: make(chan struct{}, 1)}
}

// State returns what the page may see.
func (s *Session) State() View {
	s.mu.Lock()
	defer s.mu.Unlock()
	v := View{Phase: s.phase, Prompt: s.prompt, Accounts: s.accounts, Selected: s.selected, Problem: s.problem, NextScanAt: s.nextAt}
	if s.latest != nil {
		v.Scan = &ScanInfo{FinishedAt: s.latest.FinishedAt, ID: s.latest.ID, Summary: s.latest.Summary}
	}
	return v
}

// Latest returns the last complete scan, if there is one.
func (s *Session) Latest() (scanner.Scan, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.latest == nil {
		return scanner.Scan{}, false
	}
	return *s.latest, true
}

func (s *Session) drainNudge() {
	select {
	case <-s.nudge:
	default:
	}
}

// stop cancels whatever is running and waits for it to finish. Callers must NOT hold s.mu.
func (s *Session) stop() {
	s.mu.Lock()
	cancel := s.cancel
	s.cancel = nil
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	s.wg.Wait()
	s.drainNudge() // a "scan now" aimed at the loop we just stopped must not fire in the next one
}

// Close stops everything. The session cannot be used afterwards.
func (s *Session) Close() {
	s.mu.Lock()
	s.closed = true
	s.mu.Unlock()
	s.stop()
}

// SignInParams says where to sign in. AccountID and Role are optional: when both are given (for example from an AWS CLI
// profile) the person is not asked to choose.
type SignInParams struct {
	StartURL  string
	Region    string
	AccountID string
	Role      string
}

// SignIn opens the AWS sign-in page and, once the person approves, moves on to choosing an account or scanning.
// Starting it again replaces whatever was running, but keeps the last scan so the page never goes blank.
func (s *Session) SignIn(p SignInParams) error {
	start, err := NormalizeStartURL(p.StartURL)
	if err != nil || !ValidRegion(p.Region) {
		return fmt.Errorf("%w: that is not an AWS Identity Center start URL and region", ErrBadInput)
	}
	if (p.AccountID != "" || p.Role != "") && (!ValidAccountID(p.AccountID) || !ValidRole(p.Role)) {
		return fmt.Errorf("%w: that is not a valid account and role", ErrBadInput)
	}
	s.stop()

	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return errors.New("the app is shutting down")
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	s.startURL, s.region = start, p.Region
	s.client = s.o.NewSSO(p.Region)
	s.phase, s.prompt, s.accounts, s.selected, s.problem, s.nextAt = SigningIn, nil, nil, nil, nil, nil
	client := s.client
	s.wg.Add(1)
	s.mu.Unlock()

	go func() {
		defer s.wg.Done()
		s.signInAndGo(ctx, client, start, p)
	}()
	return nil
}

func (s *Session) fail(code, message string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.phase, s.prompt, s.problem = Failed, nil, &Problem{Code: code, Message: message}
}

func (s *Session) signInAndGo(ctx context.Context, client SSO, startURL string, p SignInParams) {
	tok, err := client.SignIn(ctx, startURL, func(pr sso.Prompt) error {
		s.mu.Lock()
		s.prompt = &Prompt{URL: pr.URL, UserCode: pr.UserCode}
		s.mu.Unlock()
		if err := s.o.OpenURL(pr.URL); err != nil {
			s.o.Log("could not open the browser (the page shows the link instead): %v", err)
		}
		return nil
	})
	if ctx.Err() != nil {
		return
	}
	switch {
	case errors.Is(err, sso.ErrDenied):
		s.fail("signin_declined", "The AWS sign-in was declined. Press Connect to try again.")
		return
	case errors.Is(err, sso.ErrTimedOut):
		s.fail("signin_timeout", "The AWS sign-in was not completed in time. Press Connect to try again.")
		return
	case err != nil:
		s.o.Log("sign-in failed: %v", err)
		s.fail("signin_failed", "Could not sign in to AWS ("+describe(err)+"). Check the start URL and region, then try again.")
		return
	}

	s.mu.Lock()
	s.token, s.prompt = tok, nil
	s.mu.Unlock()

	if p.AccountID != "" {
		s.begin(ctx, p.AccountID, p.Role)
		return
	}
	accts, err := client.Accounts(ctx, tok)
	if ctx.Err() != nil {
		return
	}
	if err != nil {
		s.o.Log("listing accounts failed: %v", err)
		s.fail("signin_failed", "Signed in, but AWS would not list your accounts ("+describe(err)+").")
		return
	}
	if len(accts) == 0 {
		s.fail("no_accounts", "You are signed in, but this sign-in has no AWS accounts assigned to it.")
		return
	}
	if len(accts) == 1 {
		if roles, err := client.Roles(ctx, tok, accts[0].ID); err == nil && len(roles) == 1 {
			s.begin(ctx, accts[0].ID, roles[0])
			return
		}
	}
	s.mu.Lock()
	s.phase, s.accounts = Choosing, accts
	s.mu.Unlock()
}

// Roles lists the roles available in an account, for the person to choose from.
func (s *Session) Roles(accountID string) ([]string, error) {
	if !ValidAccountID(accountID) {
		return nil, ErrBadInput
	}
	s.mu.Lock()
	client, tok := s.client, s.token
	s.mu.Unlock()
	if client == nil || tok.AccessToken == "" {
		return nil, errors.New("sign in first")
	}
	return client.Roles(context.Background(), tok, accountID)
}

// Select chooses the account and role to scan with, and starts scanning.
func (s *Session) Select(accountID, role string) error {
	if !ValidAccountID(accountID) || !ValidRole(role) {
		return fmt.Errorf("%w: that is not a valid account and role", ErrBadInput)
	}
	s.mu.Lock()
	ready := s.phase == Choosing || s.phase == Waiting || s.phase == Scanning || s.phase == NeedsSignIn
	hasToken := s.token.AccessToken != ""
	s.mu.Unlock()
	if !ready || !hasToken {
		return errors.New("sign in first")
	}
	s.stop()
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return errors.New("the app is shutting down")
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	s.wg.Add(1)
	s.mu.Unlock()
	go func() {
		defer s.wg.Done()
		s.begin(ctx, accountID, role)
	}()
	return nil
}

// ScanNow asks for a scan right away, skipping the wait. If one is already running, one more follows it.
func (s *Session) ScanNow() {
	select {
	case s.nudge <- struct{}{}:
	default:
	}
}

// SignOut stops everything and forgets the sign-in and the scan.
func (s *Session) SignOut() {
	s.stop()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.phase, s.prompt, s.accounts, s.selected, s.problem, s.latest, s.nextAt = Idle, nil, nil, nil, nil, nil, nil
	s.token, s.client = sso.Token{}, nil
}

// begin runs the scan loop until ctx is cancelled or the sign-in expires.
func (s *Session) begin(ctx context.Context, accountID, role string) {
	s.mu.Lock()
	s.selected = &Selected{AccountID: accountID, Role: role}
	client, tok := s.client, s.token
	s.mu.Unlock()

	for {
		started := s.o.Now()
		s.mu.Lock()
		s.phase, s.nextAt = Scanning, nil
		s.mu.Unlock()

		// Fresh credentials for every scan, so one never starts with keys about to expire.
		creds, err := client.RoleCredentials(ctx, tok, accountID, role)
		if ctx.Err() != nil {
			return
		}
		switch {
		case errors.Is(err, sso.ErrExpired):
			s.mu.Lock()
			s.phase, s.nextAt = NeedsSignIn, nil
			s.problem = &Problem{Code: "sso_expired", Message: "Your AWS sign-in has expired. Sign in again to continue; the last scan stays on screen."}
			s.mu.Unlock()
			return
		case err != nil:
			s.o.Log("could not get credentials: %v", err)
			s.setProblem("credentials_failed", "Could not get credentials from AWS ("+describe(err)+"). Trying again shortly.")
		default:
			scan, err := s.o.Runner.Run(ctx, creds)
			if ctx.Err() != nil {
				return
			}
			if err != nil {
				s.o.Log("scan failed: %v", err)
				s.setProblem("scan_failed", "The last scan did not finish. Showing the previous complete scan, and trying again shortly.")
			} else {
				s.mu.Lock()
				s.latest, s.problem = &scan, nil
				s.mu.Unlock()
			}
		}

		next := started.Add(s.o.Interval)
		if floor := s.o.Now().Add(s.o.MinGap); next.Before(floor) {
			next = floor
		}
		s.mu.Lock()
		s.phase, s.nextAt = Waiting, &next
		s.mu.Unlock()

		timer := time.NewTimer(next.Sub(s.o.Now()))
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-s.nudge:
			timer.Stop()
		case <-timer.C:
		}
	}
}

func (s *Session) setProblem(code, msg string) {
	s.mu.Lock()
	s.problem = &Problem{Code: code, Message: msg}
	s.mu.Unlock()
}
