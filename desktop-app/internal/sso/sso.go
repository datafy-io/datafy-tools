// Package sso signs a person in with AWS IAM Identity Center and fetches short-lived role credentials.
//
// It does what `aws sso login` does, in-process, so the customer needs neither the AWS CLI nor a profile:
// the app registers itself as a public OIDC client, shows the user AWS's own sign-in page, polls until they
// approve, and then asks the SSO portal for credentials for the account and role they choose.
//
// Secrets (the access token and role credentials) live only in memory, and their String/GoString methods
// are redacted so an accidental %v or log line cannot print them.
package sso

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awssso "github.com/aws/aws-sdk-go-v2/service/sso"
	ssotypes "github.com/aws/aws-sdk-go-v2/service/sso/types"
	"github.com/aws/aws-sdk-go-v2/service/ssooidc"
	oidctypes "github.com/aws/aws-sdk-go-v2/service/ssooidc/types"
)

const (
	clientName    = "Datafy Discovery"
	deviceGrant   = "urn:ietf:params:oauth:grant-type:device_code"
	accountScope  = "sso:account:access"
	defaultPoll   = 5 * time.Second
	slowDownStep  = 5 * time.Second
	maxSignInWait = 10 * time.Minute
)

var (
	// ErrExpired means the sign-in is no longer valid: the person must sign in again.
	ErrExpired = errors.New("your AWS sign-in has expired")
	// ErrDenied means the person declined the sign-in in the browser.
	ErrDenied = errors.New("the AWS sign-in was declined")
	// ErrTimedOut means the sign-in page was not completed in time.
	ErrTimedOut = errors.New("the AWS sign-in was not completed in time")
)

// Token proves a completed sign-in. Never log it.
type Token struct {
	AccessToken string
	ExpiresAt   time.Time
}

func (Token) String() string   { return "sso.Token{redacted}" }
func (Token) GoString() string { return "sso.Token{redacted}" }

// Credentials are short-lived keys for one account and role. Never log them.
type Credentials struct {
	AccessKeyID     string
	SecretAccessKey string
	SessionToken    string
	Expires         time.Time
}

func (Credentials) String() string   { return "sso.Credentials{redacted}" }
func (Credentials) GoString() string { return "sso.Credentials{redacted}" }

// Account is an AWS account the person may sign in to.
type Account struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email,omitempty"`
}

// Prompt is what the person has to do: open URL and confirm the code matches.
type Prompt struct {
	URL      string
	UserCode string
	Expires  time.Time
}

// Client talks to the Identity Center OIDC and portal services of one region.
type Client struct {
	oidc   *ssooidc.Client
	portal *awssso.Client
	now    func() time.Time
	sleep  func(ctx context.Context, d time.Duration) error
}

// Option customises a Client. Production code needs none; tests point it at a fake server.
type Option func(*settings)

type settings struct {
	oidcEndpoint, portalEndpoint string
	httpClient                   *http.Client
	now                          func() time.Time
	sleep                        func(context.Context, time.Duration) error
}

// WithEndpoints sends OIDC and portal calls to the given base URLs (tests only).
func WithEndpoints(oidc, portal string) Option {
	return func(s *settings) { s.oidcEndpoint, s.portalEndpoint = oidc, portal }
}

// WithClock replaces the clock and the wait between polls (tests only).
func WithClock(now func() time.Time, sleep func(context.Context, time.Duration) error) Option {
	return func(s *settings) { s.now, s.sleep = now, sleep }
}

func realSleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// New creates a client for the Identity Center region (for example us-east-1).
func New(region string, opts ...Option) *Client {
	s := settings{now: time.Now, sleep: realSleep, httpClient: &http.Client{Timeout: 30 * time.Second}}
	for _, o := range opts {
		o(&s)
	}
	oidcOpts := ssooidc.Options{
		Region: region, HTTPClient: s.httpClient, Credentials: aws.AnonymousCredentials{}, RetryMaxAttempts: 3,
	}
	portalOpts := awssso.Options{
		Region: region, HTTPClient: s.httpClient, Credentials: aws.AnonymousCredentials{}, RetryMaxAttempts: 3,
	}
	if s.oidcEndpoint != "" {
		oidcOpts.BaseEndpoint = aws.String(s.oidcEndpoint)
	}
	if s.portalEndpoint != "" {
		portalOpts.BaseEndpoint = aws.String(s.portalEndpoint)
	}
	return &Client{oidc: ssooidc.New(oidcOpts), portal: awssso.New(portalOpts), now: s.now, sleep: s.sleep}
}

// SignIn runs the device-authorization flow. onPrompt is called once with the page the person must open;
// SignIn then waits (polling at the interval AWS asks for) until they approve, decline, or time runs out.
func (c *Client) SignIn(ctx context.Context, startURL string, onPrompt func(Prompt) error) (Token, error) {
	reg, err := c.oidc.RegisterClient(ctx, &ssooidc.RegisterClientInput{
		ClientName: aws.String(clientName), ClientType: aws.String("public"), Scopes: []string{accountScope},
	})
	if err != nil {
		return Token{}, fmt.Errorf("registering with AWS sign-in: %w", err)
	}
	auth, err := c.oidc.StartDeviceAuthorization(ctx, &ssooidc.StartDeviceAuthorizationInput{
		ClientId: reg.ClientId, ClientSecret: reg.ClientSecret, StartUrl: aws.String(startURL),
	})
	if err != nil {
		return Token{}, fmt.Errorf("starting AWS sign-in: %w", err)
	}

	wait := time.Duration(auth.ExpiresIn) * time.Second
	if wait <= 0 || wait > maxSignInWait {
		wait = maxSignInWait
	}
	deadline := c.now().Add(wait)
	interval := time.Duration(auth.Interval) * time.Second
	if interval <= 0 {
		interval = defaultPoll
	}

	url := aws.ToString(auth.VerificationUriComplete)
	if url == "" {
		url = aws.ToString(auth.VerificationUri)
	}
	if err := onPrompt(Prompt{URL: url, UserCode: aws.ToString(auth.UserCode), Expires: deadline}); err != nil {
		return Token{}, err
	}

	for {
		if err := c.sleep(ctx, interval); err != nil {
			return Token{}, err
		}
		if !c.now().Before(deadline) {
			return Token{}, ErrTimedOut
		}
		out, err := c.oidc.CreateToken(ctx, &ssooidc.CreateTokenInput{
			ClientId: reg.ClientId, ClientSecret: reg.ClientSecret,
			GrantType: aws.String(deviceGrant), DeviceCode: auth.DeviceCode,
		})
		if err == nil {
			return Token{
				AccessToken: aws.ToString(out.AccessToken),
				ExpiresAt:   c.now().Add(time.Duration(out.ExpiresIn) * time.Second),
			}, nil
		}
		var pending *oidctypes.AuthorizationPendingException
		var slow *oidctypes.SlowDownException
		var denied *oidctypes.AccessDeniedException
		var expired *oidctypes.ExpiredTokenException
		switch {
		case errors.As(err, &pending):
		case errors.As(err, &slow):
			interval += slowDownStep
		case errors.As(err, &denied):
			return Token{}, ErrDenied
		case errors.As(err, &expired):
			return Token{}, ErrTimedOut
		default:
			return Token{}, fmt.Errorf("waiting for AWS sign-in: %w", err)
		}
	}
}

func mapPortalErr(err error) error {
	var unauth *ssotypes.UnauthorizedException
	if errors.As(err, &unauth) {
		return ErrExpired
	}
	return err
}

// Accounts lists every account the person can sign in to.
func (c *Client) Accounts(ctx context.Context, tok Token) ([]Account, error) {
	var out []Account
	p := awssso.NewListAccountsPaginator(c.portal, &awssso.ListAccountsInput{AccessToken: aws.String(tok.AccessToken)})
	for p.HasMorePages() {
		page, err := p.NextPage(ctx)
		if err != nil {
			return nil, mapPortalErr(err)
		}
		for _, a := range page.AccountList {
			out = append(out, Account{ID: aws.ToString(a.AccountId), Name: aws.ToString(a.AccountName), Email: aws.ToString(a.EmailAddress)})
		}
	}
	return out, nil
}

// Roles lists the roles the person may use in one account.
func (c *Client) Roles(ctx context.Context, tok Token, accountID string) ([]string, error) {
	var out []string
	p := awssso.NewListAccountRolesPaginator(c.portal, &awssso.ListAccountRolesInput{
		AccessToken: aws.String(tok.AccessToken), AccountId: aws.String(accountID),
	})
	for p.HasMorePages() {
		page, err := p.NextPage(ctx)
		if err != nil {
			return nil, mapPortalErr(err)
		}
		for _, r := range page.RoleList {
			out = append(out, aws.ToString(r.RoleName))
		}
	}
	return out, nil
}

// RoleCredentials returns fresh short-lived credentials for the account and role. It is called before every
// scan, so a scan never starts with keys that are about to expire.
func (c *Client) RoleCredentials(ctx context.Context, tok Token, accountID, role string) (Credentials, error) {
	out, err := c.portal.GetRoleCredentials(ctx, &awssso.GetRoleCredentialsInput{
		AccessToken: aws.String(tok.AccessToken), AccountId: aws.String(accountID), RoleName: aws.String(role),
	})
	if err != nil {
		return Credentials{}, mapPortalErr(err)
	}
	rc := out.RoleCredentials
	if rc == nil || aws.ToString(rc.AccessKeyId) == "" || aws.ToString(rc.SecretAccessKey) == "" {
		return Credentials{}, errors.New("AWS returned no credentials for that role")
	}
	return Credentials{
		AccessKeyID: aws.ToString(rc.AccessKeyId), SecretAccessKey: aws.ToString(rc.SecretAccessKey),
		SessionToken: aws.ToString(rc.SessionToken), Expires: time.UnixMilli(rc.Expiration),
	}, nil
}
