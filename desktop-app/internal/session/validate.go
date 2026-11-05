package session

import (
	"errors"
	"net/url"
	"regexp"
	"strings"
)

var (
	hostRE    = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*\.awsapps\.com$`)
	regionRE  = regexp.MustCompile(`^[a-z]{2}(-[a-z]+)+-[0-9]$`)
	accountRE = regexp.MustCompile(`^[0-9]{12}$`)
	roleRE    = regexp.MustCompile(`^[A-Za-z0-9_+=,.@-]{1,64}$`)

	ErrBadInput = errors.New("invalid input")
)

// NormalizeStartURL checks an IAM Identity Center start URL (https://d-xxxxxxxxxx.awsapps.com/start) and returns it in
// a canonical form. It comes from a web page, so only AWS's own sign-in portals are accepted.
func NormalizeStartURL(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Scheme != "https" || u.User != nil || u.RawQuery != "" || u.ForceQuery || !hostRE.MatchString(u.Host) {
		return "", ErrBadInput
	}
	if strings.TrimRight(u.Path, "/") != "/start" {
		return "", ErrBadInput
	}
	return "https://" + u.Host + "/start", nil // any #fragment is dropped
}

// ValidRegion reports whether s looks like an AWS region name.
func ValidRegion(s string) bool { return regionRE.MatchString(s) }

// ValidAccountID reports whether s is a 12-digit AWS account ID.
func ValidAccountID(s string) bool { return accountRE.MatchString(s) }

// ValidRole reports whether s is a legal IAM role name.
func ValidRole(s string) bool { return roleRE.MatchString(s) }
