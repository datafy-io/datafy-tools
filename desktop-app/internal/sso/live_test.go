//go:build live

package sso

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/datafy-io/datafy-tools/desktop-app/internal/browser"
)

var errStop = errors.New("stop after the prompt: nothing is approved")

// Opt-in: go test -tags live -run Live ./internal/sso/   (optionally DATAFY_LIVE_PROFILE=<an SSO profile>)
//
// Talks to the REAL AWS Identity Center OIDC service: registers the client and starts a device authorization for the
// profile's start URL, checks the response against what the app expects, and then STOPS. It never opens a browser and
// never approves anything, so nothing is signed in. The authorization simply expires.
func TestLiveRealAWSDeviceAuthorization(t *testing.T) {
	name := os.Getenv("DATAFY_LIVE_PROFILE")
	if name == "" {
		name = "management"
	}
	profiles, err := LoadProfiles(ConfigPath())
	if err != nil {
		t.Fatal(err)
	}
	var p *Profile
	for i := range profiles {
		if profiles[i].Name == name {
			p = &profiles[i]
		}
	}
	if p == nil {
		t.Skipf("no SSO profile %q in %s", name, ConfigPath())
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	var got Prompt
	_, err = New(p.Region).SignIn(ctx, p.StartURL, func(pr Prompt) error { got = pr; return errStop })
	if !errors.Is(err, errStop) {
		t.Fatalf("expected to stop at the prompt, got: %v", err)
	}
	if got.UserCode == "" || got.URL == "" || got.Expires.Before(time.Now()) {
		t.Fatalf("incomplete prompt from real AWS: %+v", got)
	}
	if err := browser.ValidateAWSURL(got.URL); err != nil {
		t.Fatalf("real AWS handed back a URL the app would refuse to open: %s", got.URL)
	}
	t.Logf("real AWS answered: sign-in page %s, code %s, valid until %s", got.URL, got.UserCode, got.Expires.Format(time.Kitchen))
}
