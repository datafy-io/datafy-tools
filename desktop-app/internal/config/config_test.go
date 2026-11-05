package config

import "testing"

func TestOnlyExactOriginsAreAllowed(t *testing.T) {
	for _, o := range AllowedOrigins() {
		if !IsAllowedOrigin(o) {
			t.Fatalf("%s should be allowed", o)
		}
	}
	for _, bad := range []string{
		"", "*", "null", "https://evil.example.com", "http://app.datafy.io", "https://app.datafy.io.evil.io",
		"https://app.datafy.io/", "https://app.datafy.io:8443", "https://APP.DATAFY.IO", "https://sub.app.datafy.io",
	} {
		if IsAllowedOrigin(bad) {
			t.Errorf("%q must not be allowed", bad)
		}
	}
}

func TestProductionBuildDoesNotTrustLocalhost(t *testing.T) {
	if IsAllowedOrigin("http://localhost:3000") {
		t.Skip("running a dev build (-tags dev), where localhost is allowed on purpose")
	}
}

func TestAllowedOriginsReturnsACopy(t *testing.T) {
	a := AllowedOrigins()
	a[0] = "https://evil.example.com"
	if IsAllowedOrigin("https://evil.example.com") {
		t.Fatal("callers must not be able to change the allowlist")
	}
}
