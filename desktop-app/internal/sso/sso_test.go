package sso

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// fake is an Identity Center OIDC + portal server that speaks the real wire protocol.
type fake struct {
	mu       sync.Mutex
	tokenSeq []string // what POST /token answers, in order: "pending", "slow_down", "denied", "expired", "ok"
	polls    int
	accounts []map[string]string
	roles    map[string][]string
	bearer   string // token the portal accepts
	interval int
	expires  int
	seenAuth []string
	failReg  bool
}

func (f *fake) server(t *testing.T) *httptest.Server {
	mux := http.NewServeMux()
	writeErr := func(w http.ResponseWriter, status int, typ, code string) {
		w.Header().Set("X-Amzn-Errortype", typ)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": code, "error_description": typ, "message": typ})
	}
	jsonOut := func(w http.ResponseWriter, v any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(v)
	}
	mux.HandleFunc("/client/register", func(w http.ResponseWriter, r *http.Request) {
		if f.failReg {
			writeErr(w, 400, "InvalidClientMetadataException", "invalid_client_metadata")
			return
		}
		var in map[string]any
		_ = json.NewDecoder(r.Body).Decode(&in)
		if in["clientType"] != "public" {
			t.Errorf("must register as a public client, got %v", in["clientType"])
		}
		jsonOut(w, map[string]any{"clientId": "cid", "clientSecret": "csecret", "clientIdIssuedAt": 1, "clientSecretExpiresAt": 2})
	})
	mux.HandleFunc("/device_authorization", func(w http.ResponseWriter, r *http.Request) {
		var in map[string]any
		_ = json.NewDecoder(r.Body).Decode(&in)
		if in["startUrl"] != "https://d-1.awsapps.com/start" {
			t.Errorf("start URL not forwarded: %v", in["startUrl"])
		}
		jsonOut(w, map[string]any{
			"deviceCode": "dcode", "userCode": "ABCD-EFGH", "verificationUri": "https://device.sso.us-east-1.amazonaws.com/",
			"verificationUriComplete": "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH",
			"expiresIn":               f.expires, "interval": f.interval,
		})
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		var in map[string]any
		_ = json.NewDecoder(r.Body).Decode(&in)
		if in["grantType"] != deviceGrant || in["deviceCode"] != "dcode" || in["clientId"] != "cid" {
			t.Errorf("bad token request: %v", in)
		}
		step := "ok"
		if f.polls < len(f.tokenSeq) {
			step = f.tokenSeq[f.polls]
		}
		f.polls++
		switch step {
		case "pending":
			writeErr(w, 400, "AuthorizationPendingException", "authorization_pending")
		case "slow_down":
			writeErr(w, 400, "SlowDownException", "slow_down")
		case "denied":
			writeErr(w, 400, "AccessDeniedException", "access_denied")
		case "expired":
			writeErr(w, 400, "ExpiredTokenException", "expired_token")
		default:
			jsonOut(w, map[string]any{"accessToken": f.bearer, "tokenType": "Bearer", "expiresIn": 28800})
		}
	})
	portal := func(h http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			f.mu.Lock()
			f.seenAuth = append(f.seenAuth, r.Header.Get("X-Amz-Sso_bearer_token"))
			f.mu.Unlock()
			if r.Header.Get("X-Amz-Sso_bearer_token") != f.bearer {
				writeErr(w, 401, "UnauthorizedException", "Session token not found or invalid")
				return
			}
			h(w, r)
		}
	}
	mux.HandleFunc("/assignment/accounts", portal(func(w http.ResponseWriter, r *http.Request) {
		start := 0
		if tok := r.URL.Query().Get("next_token"); tok != "" {
			fmt.Sscanf(tok, "%d", &start)
		}
		end := start + 2
		out := map[string]any{"accountList": f.accounts[start:min(end, len(f.accounts))]}
		if end < len(f.accounts) {
			out["nextToken"] = fmt.Sprint(end)
		}
		jsonOut(w, out)
	}))
	mux.HandleFunc("/assignment/roles", portal(func(w http.ResponseWriter, r *http.Request) {
		var rl []map[string]string
		for _, name := range f.roles[r.URL.Query().Get("account_id")] {
			rl = append(rl, map[string]string{"roleName": name, "accountId": r.URL.Query().Get("account_id")})
		}
		jsonOut(w, map[string]any{"roleList": rl})
	}))
	mux.HandleFunc("/federation/credentials", portal(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("role_name") == "Nope" {
			writeErr(w, 404, "ResourceNotFoundException", "no such role")
			return
		}
		jsonOut(w, map[string]any{"roleCredentials": map[string]any{
			"accessKeyId": "ASIAFAKE", "secretAccessKey": "fakesecret", "sessionToken": "faketoken", "expiration": 1900000000000,
		}})
	}))
	s := httptest.NewServer(mux)
	t.Cleanup(s.Close)
	return s
}

type clockT struct {
	now    time.Time
	slept  []time.Duration
	onWait func()
}

func (c *clockT) Now() time.Time { return c.now }
func (c *clockT) Sleep(ctx context.Context, d time.Duration) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	c.slept = append(c.slept, d)
	c.now = c.now.Add(d)
	if c.onWait != nil {
		c.onWait()
	}
	return nil
}

func setup(t *testing.T, f *fake) (*Client, *clockT) {
	if f.interval == 0 {
		f.interval = 1
	}
	if f.expires == 0 {
		f.expires = 600
	}
	if f.bearer == "" {
		f.bearer = "bearer-token"
	}
	s := f.server(t)
	clk := &clockT{now: time.Unix(1_800_000_000, 0)}
	return New("us-east-1", WithEndpoints(s.URL, s.URL), WithClock(clk.Now, clk.Sleep)), clk
}

func TestSignInWaitsForApprovalAndReturnsAToken(t *testing.T) {
	f := &fake{tokenSeq: []string{"pending", "pending", "ok"}}
	c, clk := setup(t, f)
	var got Prompt
	tok, err := c.SignIn(context.Background(), "https://d-1.awsapps.com/start", func(p Prompt) error { got = p; return nil })
	if err != nil {
		t.Fatal(err)
	}
	if tok.AccessToken != "bearer-token" || !tok.ExpiresAt.After(clk.now) {
		t.Fatalf("token: %+v", tok)
	}
	if got.URL != "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH" || got.UserCode != "ABCD-EFGH" {
		t.Fatalf("prompt: %+v", got)
	}
	if f.polls != 3 || len(clk.slept) != 3 {
		t.Fatalf("polled %d times, slept %v", f.polls, clk.slept)
	}
}

func TestSignInBacksOffWhenAWSSaysSlowDown(t *testing.T) {
	f := &fake{tokenSeq: []string{"pending", "slow_down", "pending", "ok"}}
	c, clk := setup(t, f)
	if _, err := c.SignIn(context.Background(), "https://d-1.awsapps.com/start", func(Prompt) error { return nil }); err != nil {
		t.Fatal(err)
	}
	want := []time.Duration{1 * time.Second, 1 * time.Second, 6 * time.Second, 6 * time.Second}
	if fmt.Sprint(clk.slept) != fmt.Sprint(want) {
		t.Fatalf("waits %v, want %v", clk.slept, want)
	}
}

func TestSignInOutcomes(t *testing.T) {
	cases := map[string]struct {
		seq  []string
		want error
	}{
		"declined": {[]string{"pending", "denied"}, ErrDenied},
		"expired":  {[]string{"expired"}, ErrTimedOut},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			c, _ := setup(t, &fake{tokenSeq: tc.seq})
			_, err := c.SignIn(context.Background(), "https://d-1.awsapps.com/start", func(Prompt) error { return nil })
			if !errors.Is(err, tc.want) {
				t.Fatalf("got %v, want %v", err, tc.want)
			}
		})
	}
}

func TestSignInGivesUpWhenTheWindowCloses(t *testing.T) {
	f := &fake{tokenSeq: strings.Fields(strings.Repeat("pending ", 50)), interval: 5, expires: 20}
	c, _ := setup(t, f)
	_, err := c.SignIn(context.Background(), "https://d-1.awsapps.com/start", func(Prompt) error { return nil })
	if !errors.Is(err, ErrTimedOut) {
		t.Fatalf("got %v", err)
	}
	if f.polls > 4 {
		t.Fatalf("kept polling past the deadline: %d polls", f.polls)
	}
}

func TestSignInStopsWhenCancelledOrWhenThePromptFails(t *testing.T) {
	c, _ := setup(t, &fake{tokenSeq: []string{"pending", "pending", "pending"}})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := c.SignIn(ctx, "https://d-1.awsapps.com/start", func(Prompt) error { return nil }); err == nil {
		t.Fatal("a cancelled sign-in must stop")
	}
	c, _ = setup(t, &fake{})
	boom := errors.New("no browser")
	if _, err := c.SignIn(context.Background(), "https://d-1.awsapps.com/start", func(Prompt) error { return boom }); !errors.Is(err, boom) {
		t.Fatalf("got %v", err)
	}
}

func TestRegistrationFailureIsReported(t *testing.T) {
	c, _ := setup(t, &fake{failReg: true})
	_, err := c.SignIn(context.Background(), "https://d-1.awsapps.com/start", func(Prompt) error { return nil })
	if err == nil || !strings.Contains(err.Error(), "registering") {
		t.Fatalf("got %v", err)
	}
}

func TestAccountsRolesAndCredentials(t *testing.T) {
	f := &fake{
		accounts: []map[string]string{
			{"accountId": "1", "accountName": "one", "emailAddress": "a@x"}, {"accountId": "2", "accountName": "two"},
			{"accountId": "3", "accountName": "three"}, {"accountId": "4", "accountName": "four"}, {"accountId": "5", "accountName": "five"},
		},
		roles: map[string][]string{"1": {"Admin", "ReadOnly"}},
	}
	c, _ := setup(t, f)
	tok := Token{AccessToken: "bearer-token"}
	ctx := context.Background()

	accts, err := c.Accounts(ctx, tok)
	if err != nil || len(accts) != 5 || accts[0] != (Account{ID: "1", Name: "one", Email: "a@x"}) {
		t.Fatalf("accounts across pages: %+v, %v", accts, err)
	}
	roles, err := c.Roles(ctx, tok, "1")
	if err != nil || fmt.Sprint(roles) != "[Admin ReadOnly]" {
		t.Fatalf("roles: %v, %v", roles, err)
	}
	creds, err := c.RoleCredentials(ctx, tok, "1", "Admin")
	if err != nil || creds.AccessKeyID != "ASIAFAKE" || creds.SecretAccessKey != "fakesecret" || creds.SessionToken != "faketoken" {
		t.Fatalf("creds: %+v, %v", creds, err)
	}
	if creds.Expires.UnixMilli() != 1900000000000 {
		t.Fatalf("expiry %v", creds.Expires)
	}
	for _, a := range f.seenAuth {
		if a != "bearer-token" {
			t.Fatalf("the portal must always be sent the bearer token, saw %q", a)
		}
	}
}

func TestAnInvalidTokenMeansSignInAgain(t *testing.T) {
	c, _ := setup(t, &fake{accounts: []map[string]string{{"accountId": "1"}}})
	bad := Token{AccessToken: "stale"}
	if _, err := c.Accounts(context.Background(), bad); !errors.Is(err, ErrExpired) {
		t.Fatalf("accounts: %v", err)
	}
	if _, err := c.Roles(context.Background(), bad, "1"); !errors.Is(err, ErrExpired) {
		t.Fatalf("roles: %v", err)
	}
	if _, err := c.RoleCredentials(context.Background(), bad, "1", "Admin"); !errors.Is(err, ErrExpired) {
		t.Fatalf("credentials: %v", err)
	}
}

func TestOtherPortalErrorsAreNotMistakenForAnExpiredSignIn(t *testing.T) {
	c, _ := setup(t, &fake{})
	_, err := c.RoleCredentials(context.Background(), Token{AccessToken: "bearer-token"}, "1", "Nope")
	if err == nil || errors.Is(err, ErrExpired) {
		t.Fatalf("a missing role is not an expired sign-in: %v", err)
	}
}

func TestSecretsAreRedactedWhenPrinted(t *testing.T) {
	creds := Credentials{AccessKeyID: "ASIASECRETKEY", SecretAccessKey: "supersecretvalue", SessionToken: "sessiontokenvalue"}
	tok := Token{AccessToken: "bearertokenvalue"}
	for _, s := range []string{
		fmt.Sprintf("%v %+v %#v %s", creds, creds, creds, creds), fmt.Sprintf("%v %+v %#v %s", tok, tok, tok, tok),
		fmt.Sprint(&creds), fmt.Sprint([]Credentials{creds}), fmt.Sprint(map[string]Token{"t": tok}),
	} {
		for _, secret := range []string{"ASIASECRETKEY", "supersecretvalue", "sessiontokenvalue", "bearertokenvalue"} {
			if strings.Contains(s, secret) {
				t.Fatalf("%q leaked in %q", secret, s)
			}
		}
	}
}
