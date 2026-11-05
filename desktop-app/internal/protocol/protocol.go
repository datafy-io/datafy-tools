// Package protocol parses the datafy-discovery://open?origin=...&nonce=... link a Datafy page uses to start the app.
//
// Any web page on the internet can try to open this link, so everything in it is treated as hostile: the
// origin must be on the allowlist, the secret must look like a secret, and nothing unexpected may be present.
package protocol

import (
	"errors"
	"net/url"
	"regexp"
	"strings"

	"github.com/datafy-io/datafy-tools/desktop-app/internal/config"
)

// Launch is what a valid link asks for: let this origin talk to the app, using this secret.
type Launch struct {
	Origin string
	// Nonce is a secret the page generates and puts in the link. The app only answers requests that repeat it,
	// so a different page on the same machine cannot join the session.
	Nonce string
}

var nonceRE = regexp.MustCompile(`^[A-Za-z0-9_-]{16,128}$`)

var ErrInvalid = errors.New("invalid launch link")

// ValidOrigin reports whether s is exactly scheme://host[:port]: no path, query, fragment or userinfo.
func ValidOrigin(s string) bool {
	u, err := url.Parse(s)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return false
	}
	return u.User == nil && u.Path == "" && u.RawQuery == "" && u.Fragment == "" && !u.ForceQuery &&
		u.Scheme+"://"+u.Host == s
}

// ValidNonce reports whether s is an acceptable secret.
func ValidNonce(s string) bool { return nonceRE.MatchString(s) }

// Parse validates a launch link. allowed decides which origins may use the app (config.IsAllowedOrigin in production).
func Parse(raw string, allowed func(origin string) bool) (Launch, error) {
	u, err := url.Parse(raw)
	if err != nil || !strings.EqualFold(u.Scheme, config.Scheme) {
		return Launch{}, ErrInvalid
	}
	if u.Host != "open" || (u.Path != "" && u.Path != "/") || u.Fragment != "" || u.User != nil {
		return Launch{}, ErrInvalid
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil || len(q) != 2 {
		return Launch{}, ErrInvalid
	}
	origin, nonce := q["origin"], q["nonce"]
	if len(origin) != 1 || len(nonce) != 1 || !ValidOrigin(origin[0]) || !ValidNonce(nonce[0]) {
		return Launch{}, ErrInvalid
	}
	if !allowed(origin[0]) {
		return Launch{}, ErrInvalid
	}
	return Launch{Origin: origin[0], Nonce: nonce[0]}, nil
}
