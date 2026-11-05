//go:build live

package scanner

import (
	"context"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// Opt-in: go test -tags live -run Live ./internal/scanner/
// Downloads the real pinned scanner from GitHub through the app's own code, verifies it, and runs it.
func TestLiveDownloadVerifyAndRun(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	path, err := Fetcher{CacheDir: t.TempDir()}.Ensure(ctx)
	if err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command(path, "--version").CombinedOutput()
	if err != nil || !strings.Contains(string(out), "0.2.1") {
		t.Fatalf("%q %v", out, err)
	}
	t.Logf("downloaded, checksum-verified and ran: %s", strings.TrimSpace(string(out)))
}
