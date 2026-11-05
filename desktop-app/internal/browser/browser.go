// Package browser opens the AWS sign-in page in the user's browser.
package browser

import (
	"errors"
	"net/url"
	"os/exec"
	"regexp"
	"runtime"
	"strings"
)

var awsHost = regexp.MustCompile(`(^|\.)(awsapps\.com|amazonaws\.com|amazonaws\.com\.cn|aws\.amazon\.com|aws)$`)

var ErrNotAWS = errors.New("refusing to open a URL that is not an AWS sign-in page")

// ValidateAWSURL accepts only https URLs on AWS's own sign-in domains. The URL comes from AWS's response, but
// the app still refuses to hand anything else to the operating system.
func ValidateAWSURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || !awsHost.MatchString(strings.ToLower(u.Hostname())) {
		return ErrNotAWS
	}
	return nil
}

// command returns the program and arguments that open url on the given OS. The URL is always a single argument,
// never part of a shell string, so it cannot be interpreted as anything else.
func command(goos, rawURL string) (string, []string) {
	switch goos {
	case "darwin":
		return "open", []string{rawURL}
	case "windows":
		return "rundll32", []string{"url.dll,FileProtocolHandler", rawURL}
	default:
		return "xdg-open", []string{rawURL}
	}
}

// Open opens rawURL in the default browser.
func Open(rawURL string) error {
	if err := ValidateAWSURL(rawURL); err != nil {
		return err
	}
	name, args := command(runtime.GOOS, rawURL)
	return exec.Command(name, args...).Start()
}
