package scanner

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/datafy-io/datafy-tools/desktop-app/internal/config"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/sso"
)

// Summary is the last line of a scan file.
type Summary struct {
	ToolVersion     string `json:"tool_version"`
	ScannedAt       string `json:"scanned_at"`
	Interrupted     bool   `json:"interrupted"`
	AccountsTotal   int    `json:"accounts_total"`
	AccountsScanned int    `json:"accounts_scanned"`
	AccountsSkipped int    `json:"accounts_skipped"`
	AccountsFailed  int    `json:"accounts_failed"`
	RegionsScanned  int    `json:"regions_scanned"`
	RegionsPartial  int    `json:"regions_partial"`
	RegionsFailed   int    `json:"regions_failed"`
}

// Scan is one complete, validated scan.
type Scan struct {
	Data    []byte // the scan file, one JSON object per line, summary last
	Summary Summary
	// ID identifies the content, so the page can ask "has it changed?" without downloading it again.
	ID         string
	FinishedAt time.Time
}

// Runner produces a scan from credentials. The real one runs the discovery scanner; tests use a fake.
type Runner interface {
	Run(ctx context.Context, creds sso.Credentials) (Scan, error)
}

// Exec runs the discovery scanner binary.
type Exec struct {
	Binary  string
	Timeout time.Duration
	// Log receives the scanner's own progress text (never credentials: the scanner does not print them).
	Log func(string)
}

// passthrough are the only variables the scanner inherits from the app's environment: enough to reach the
// internet through a corporate proxy and trust its certificates, and nothing that could redirect AWS access.
var passthrough = []string{
	"PATH", "TMPDIR", "TEMP", "TMP", "SYSTEMROOT", "WINDIR",
	"HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
	"SSL_CERT_FILE", "SSL_CERT_DIR", "AWS_CA_BUNDLE",
}

// Env builds the scanner's environment: the fresh credentials, plus the allowlisted variables above. Anything else
// from the user's environment (another AWS_PROFILE, stray AWS_* keys, endpoint overrides) is deliberately dropped,
// so the scan can only ever run as the account and role the person chose.
func Env(parent []string, c sso.Credentials) []string {
	have := map[string]string{}
	for _, kv := range parent {
		if k, v, ok := strings.Cut(kv, "="); ok {
			have[k] = v
		}
	}
	var env []string
	for _, k := range passthrough {
		if v, ok := have[k]; ok {
			env = append(env, k+"="+v)
		}
	}
	return append(env,
		"AWS_ACCESS_KEY_ID="+c.AccessKeyID,
		"AWS_SECRET_ACCESS_KEY="+c.SecretAccessKey,
		"AWS_SESSION_TOKEN="+c.SessionToken,
		"AWS_REGION=us-east-1",
		"AWS_EC2_METADATA_DISABLED=true",
		"AWS_CONFIG_FILE="+os.DevNull,
		"AWS_SHARED_CREDENTIALS_FILE="+os.DevNull,
	)
}

var ErrIncomplete = errors.New("the scan did not finish")

// majorMinor turns "0.2.1" into "0.2". Anything that is not x.y.z gives "", which never matches.
func majorMinor(v string) string {
	parts := strings.Split(v, ".")
	if len(parts) < 2 || parts[0] == "" || parts[1] == "" {
		return ""
	}
	return parts[0] + "." + parts[1]
}

// Parse validates scan file contents: every line is JSON, the summary is last, the tool version is the one this
// app understands, and the scan was not interrupted. Anything else is an error, never a partial result.
func Parse(data []byte) (Summary, error) {
	lines := bytes.Split(bytes.TrimSpace(data), []byte("\n"))
	if len(lines) == 0 || len(bytes.TrimSpace(lines[0])) == 0 {
		return Summary{}, fmt.Errorf("%w: the file is empty", ErrIncomplete)
	}
	var last struct {
		RecordType string `json:"record_type"`
		Summary
	}
	for i, l := range lines {
		var probe struct {
			RecordType string `json:"record_type"`
		}
		if err := json.Unmarshal(l, &probe); err != nil || probe.RecordType == "" {
			return Summary{}, fmt.Errorf("%w: line %d is not a scan record", ErrIncomplete, i+1)
		}
		if probe.RecordType == "summary" && i != len(lines)-1 {
			return Summary{}, fmt.Errorf("%w: data after the summary", ErrIncomplete)
		}
	}
	if err := json.Unmarshal(lines[len(lines)-1], &last); err != nil || last.RecordType != "summary" {
		return Summary{}, fmt.Errorf("%w: no summary at the end", ErrIncomplete)
	}
	if want := majorMinor(config.ScannerToolVersion); majorMinor(last.ToolVersion) != want {
		return Summary{}, fmt.Errorf("the scanner reported version %q, but this app understands %s.x", last.ToolVersion, want)
	}
	if last.Interrupted {
		return Summary{}, fmt.Errorf("%w: it was interrupted", ErrIncomplete)
	}
	return last.Summary, nil
}

// Run scans every account the credentials can reach and returns the validated result.
func (e Exec) Run(ctx context.Context, creds sso.Credentials) (Scan, error) {
	timeout := e.Timeout
	if timeout == 0 {
		timeout = config.ScanTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	dir, err := os.MkdirTemp("", "datafy-scan-")
	if err != nil {
		return Scan{}, err
	}
	defer os.RemoveAll(dir)
	out := filepath.Join(dir, "scan.json")

	cmd := exec.CommandContext(ctx, e.Binary, "--output", out)
	cmd.Env = Env(os.Environ(), creds)
	configure(cmd)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	runErr := cmd.Run()
	if e.Log != nil && stderr.Len() > 0 {
		e.Log(strings.TrimSpace(stderr.String()))
	}
	if ctx.Err() == context.DeadlineExceeded {
		return Scan{}, fmt.Errorf("%w: it took longer than %s", ErrIncomplete, timeout)
	}
	if runErr != nil {
		return Scan{}, fmt.Errorf("%w: the scanner exited with an error", ErrIncomplete)
	}
	data, err := os.ReadFile(out)
	if err != nil {
		return Scan{}, fmt.Errorf("%w: no output file", ErrIncomplete)
	}
	sum, err := Parse(data)
	if err != nil {
		return Scan{}, err
	}
	h := sha256.Sum256(data)
	finished, perr := time.Parse(time.RFC3339, sum.ScannedAt)
	if perr != nil {
		finished = time.Now()
	}
	return Scan{Data: data, Summary: sum, ID: hex.EncodeToString(h[:8]), FinishedAt: finished}, nil
}
