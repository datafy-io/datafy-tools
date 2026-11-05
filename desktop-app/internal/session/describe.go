package session

import (
	"context"
	"errors"
	"net"
	"regexp"

	"github.com/aws/smithy-go"
)

var codeRE = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,64}$`)

// describe turns an error into a short label that is safe to show on the page: an AWS error code such as
// "ThrottlingException", or a generic phrase. It never returns the error's own text, which could carry anything;
// the full error goes to the local log only.
func describe(err error) string {
	var api smithy.APIError
	switch {
	case errors.As(err, &api) && codeRE.MatchString(api.ErrorCode()):
		return api.ErrorCode()
	case errors.Is(err, context.DeadlineExceeded):
		return "timed out"
	}
	var ne net.Error
	if errors.As(err, &ne) {
		return "a network problem"
	}
	return "an unexpected error"
}
