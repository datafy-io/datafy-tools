package scanner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/datafy-io/datafy-tools/desktop-app/internal/config"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/sso"
)

const goodScan = `{"record_type":"region","account_id":"1","region":"us-east-1","status":"ok","volumes":[],"instances":[]}
{"record_type":"summary","tool_version":"0.2.1","scanned_at":"2026-01-01T00:00:00Z","interrupted":false,"accounts_total":1,"accounts_scanned":1,"accounts_skipped":0,"accounts_failed":0,"regions_scanned":1,"regions_partial":0,"regions_failed":0}
`

func TestPinsAreCompleteAndMatchThePluginsLockFile(t *testing.T) {
	hex64 := regexp.MustCompile(`^[0-9a-f]{64}$`)
	seen := map[string]bool{}
	for platform, a := range Pins() {
		if !hex64.MatchString(a.SHA256) || seen[a.SHA256] {
			t.Errorf("%s: bad or duplicate checksum %q", platform, a.SHA256)
		}
		seen[a.SHA256] = true
	}
	if len(Pins()) != 6 {
		t.Errorf("expected six platforms, got %d", len(Pins()))
	}
	// The AWS Explorer plugin pins the same release. Two pins that drift apart are a bug waiting to be shipped.
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "plugins", "datafy-aws-explorer", "scanner.lock.json"))
	if err != nil {
		t.Skipf("plugin lock file not found (building outside the repo): %v", err)
	}
	var lock struct {
		Release     string            `json:"release"`
		ToolVersion string            `json:"tool_version"`
		Assets      map[string]string `json:"assets"`
	}
	if err := json.Unmarshal(raw, &lock); err != nil {
		t.Fatal(err)
	}
	if lock.Release != config.ScannerRelease || lock.ToolVersion != config.ScannerToolVersion {
		t.Errorf("release/tool version differ from the plugin's lock: %s/%s vs %s/%s", config.ScannerRelease, config.ScannerToolVersion, lock.Release, lock.ToolVersion)
	}
	for platform, a := range Pins() {
		if lock.Assets[a.Name] != a.SHA256 {
			t.Errorf("%s: checksum differs from the plugin's lock file", platform)
		}
	}
}

func TestUnsupportedPlatformsAreRefused(t *testing.T) {
	if _, err := AssetFor("plan9", "mips"); err == nil {
		t.Fatal("expected an error")
	}
}

// --- downloading -----------------------------------------------------------------------------------------------

func serve(t *testing.T, body []byte, hits *int32) *httptest.Server {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(hits, 1)
		if strings.HasSuffix(r.URL.Path, "/missing") {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(body)
	}))
	t.Cleanup(s.Close)
	return s
}

func fetcherFor(t *testing.T, srv *httptest.Server, content []byte) Fetcher {
	h := sha256.Sum256(content)
	pins["test/amd64"] = Asset{Name: "scanner-bin", SHA256: hex.EncodeToString(h[:])}
	t.Cleanup(func() { delete(pins, "test/amd64") })
	return Fetcher{CacheDir: t.TempDir(), BaseURL: srv.URL, GOOS: "test", GOARCH: "amd64"}
}

func TestDownloadVerifyAndReuse(t *testing.T) {
	var hits int32
	content := []byte("#!/bin/sh\necho real scanner\n")
	srv := serve(t, content, &hits)
	f := fetcherFor(t, srv, content)

	path, err := f.Ensure(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(path); string(got) != string(content) {
		t.Fatal("wrong file content")
	}
	if runtime.GOOS != "windows" {
		if st, _ := os.Stat(path); st.Mode()&0o100 == 0 {
			t.Fatal("the scanner must be executable")
		}
	}
	if _, err := f.Ensure(context.Background()); err != nil || hits != 1 {
		t.Fatalf("a verified cached copy must be reused without downloading again (hits=%d, err=%v)", hits, err)
	}
}

func TestATamperedDownloadIsNeverKept(t *testing.T) {
	var hits int32
	srv := serve(t, []byte("evil bytes"), &hits)
	f := fetcherFor(t, srv, []byte("the real bytes"))
	if _, err := f.Ensure(context.Background()); !errors.Is(err, ErrChecksum) {
		t.Fatalf("got %v", err)
	}
	entries, _ := os.ReadDir(filepath.Join(f.CacheDir, config.ScannerRelease))
	for _, e := range entries {
		t.Errorf("nothing may be left behind after a checksum failure, found %s", e.Name())
	}
}

func TestACachedCopyThatWasReplacedIsDownloadedAgain(t *testing.T) {
	var hits int32
	content := []byte("#!/bin/sh\necho real\n")
	srv := serve(t, content, &hits)
	f := fetcherFor(t, srv, content)
	path, _ := f.Ensure(context.Background())
	if err := os.WriteFile(path, []byte("replaced by something else"), 0o700); err != nil {
		t.Fatal(err)
	}
	path, err := f.Ensure(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(path); string(got) != string(content) || hits != 2 {
		t.Fatalf("a replaced cached copy must be refetched and re-verified (hits=%d)", hits)
	}
}

func TestDownloadFailuresAreReported(t *testing.T) {
	var hits int32
	srv := serve(t, nil, &hits)
	f := fetcherFor(t, srv, []byte("x"))
	pins["test/amd64"] = Asset{Name: "missing", SHA256: pins["test/amd64"].SHA256}
	if _, err := f.Ensure(context.Background()); err == nil || !strings.Contains(err.Error(), "404") {
		t.Fatalf("got %v", err)
	}
}

func TestAnOverrideSkipsTheDownloadForDevelopment(t *testing.T) {
	p, err := Fetcher{Override: "/tmp/my-scanner"}.Ensure(context.Background())
	if err != nil || p != "/tmp/my-scanner" {
		t.Fatalf("%q %v", p, err)
	}
}

// --- parsing -------------------------------------------------------------------------------------------------

func TestParseAcceptsOnlyACompleteScan(t *testing.T) {
	sum, err := Parse([]byte(goodScan))
	if err != nil || sum.AccountsTotal != 1 || sum.ToolVersion != "0.2.1" {
		t.Fatalf("%+v %v", sum, err)
	}
	region := strings.Split(goodScan, "\n")[0]
	summary := strings.Split(goodScan, "\n")[1]
	bad := map[string]string{
		"empty":                   "",
		"whitespace":              "\n \n",
		"no summary":              region + "\n",
		"data after the summary":  goodScan + region + "\n",
		"a non-JSON line":         region + "\nnot json\n" + summary + "\n",
		"a line cut off":          goodScan[:len(goodScan)-40],
		"a record without a type": `{"a":1}` + "\n" + summary + "\n",
		"another tool version":    strings.Replace(goodScan, `"0.2.1"`, `"0.3.0"`, 1),
		"no tool version":         strings.Replace(goodScan, `"tool_version":"0.2.1",`, "", 1),
		"interrupted":             strings.Replace(goodScan, `"interrupted":false`, `"interrupted":true`, 1),
	}
	for name, data := range bad {
		if _, err := Parse([]byte(data)); err == nil {
			t.Errorf("%s: must be refused", name)
		}
	}
	if _, err := Parse([]byte(strings.Replace(goodScan, `"0.2.1"`, `"0.2.9"`, 1))); err != nil {
		t.Errorf("a patch release of the same minor version is fine: %v", err)
	}
}

// --- the environment the scanner gets ----------------------------------------------------------------------------

func TestTheScannerOnlyEverSeesTheChosenCredentialsAndASafeEnvironment(t *testing.T) {
	parent := []string{
		"PATH=/usr/bin", "HTTPS_PROXY=http://proxy:3128", "SSL_CERT_FILE=/etc/ca.pem", "HOME=/Users/me",
		"AWS_PROFILE=some-other-account", "AWS_ACCESS_KEY_ID=AKIAOTHERPERSON", "AWS_SECRET_ACCESS_KEY=othersecret",
		"AWS_SESSION_TOKEN=othertoken", "AWS_ENDPOINT_URL=http://evil.example.com", "AWS_ROLE_ARN=arn:aws:iam::9:role/x",
		"AWS_WEB_IDENTITY_TOKEN_FILE=/tmp/t", "AWS_REGION=eu-west-3", "AWS_DEFAULT_REGION=eu-west-3", "SECRET_THING=1",
	}
	env := strings.Join(Env(parent, sso.Credentials{AccessKeyID: "ASIAMINE", SecretAccessKey: "minesecret", SessionToken: "minetoken"}), "\n")
	for _, must := range []string{
		"AWS_ACCESS_KEY_ID=ASIAMINE", "AWS_SECRET_ACCESS_KEY=minesecret", "AWS_SESSION_TOKEN=minetoken",
		"PATH=/usr/bin", "HTTPS_PROXY=http://proxy:3128", "SSL_CERT_FILE=/etc/ca.pem", "AWS_EC2_METADATA_DISABLED=true",
		"AWS_REGION=us-east-1", "AWS_CONFIG_FILE=" + os.DevNull,
	} {
		if !strings.Contains(env, must) {
			t.Errorf("missing %s", must)
		}
	}
	for _, mustNot := range []string{
		"AWS_PROFILE", "AKIAOTHERPERSON", "othersecret", "othertoken", "AWS_ENDPOINT_URL", "AWS_ROLE_ARN",
		"AWS_WEB_IDENTITY_TOKEN_FILE", "eu-west-3", "SECRET_THING", "HOME=",
	} {
		if strings.Contains(env, mustNot) {
			t.Errorf("%s must not reach the scanner", mustNot)
		}
	}
}

// --- running a scanner ---------------------------------------------------------------------------------------

func fakeScanner(t *testing.T, body string) string {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script scanner")
	}
	p := filepath.Join(t.TempDir(), "scanner")
	script := "#!/bin/sh\nout=\"$2\"\n" + body
	if err := os.WriteFile(p, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	return p
}

var creds = sso.Credentials{AccessKeyID: "ASIATESTKEY", SecretAccessKey: "testsecretvalue", SessionToken: "testtokenvalue"}

func TestRunReturnsAValidatedScan(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "scan.src")
	_ = os.WriteFile(src, []byte(goodScan), 0o600)
	dump := filepath.Join(dir, "env.txt")
	bin := fakeScanner(t, "env > '"+dump+"'\ncp '"+src+"' \"$out\"\necho progress line >&2\n")
	var logged []string
	scan, err := Exec{Binary: bin, Log: func(s string) { logged = append(logged, s) }}.Run(context.Background(), creds)
	if err != nil {
		t.Fatal(err)
	}
	if string(scan.Data) != goodScan || scan.Summary.AccountsScanned != 1 || scan.ID == "" || scan.FinishedAt.Year() != 2026 {
		t.Fatalf("%+v", scan.Summary)
	}
	envDump, _ := os.ReadFile(dump)
	if !strings.Contains(string(envDump), "AWS_ACCESS_KEY_ID=ASIATESTKEY") || strings.Contains(string(envDump), "AWS_PROFILE") {
		t.Fatalf("the scanner got the wrong environment:\n%s", envDump)
	}
	if strings.Join(logged, "") != "progress line" {
		t.Fatalf("the scanner's own output should be logged: %v", logged)
	}
}

func TestTheSameContentGivesTheSameID(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "scan.src")
	_ = os.WriteFile(src, []byte(goodScan), 0o600)
	bin := fakeScanner(t, "cp '"+src+"' \"$out\"\n")
	a, _ := Exec{Binary: bin}.Run(context.Background(), creds)
	b, _ := Exec{Binary: bin}.Run(context.Background(), creds)
	if a.ID == "" || a.ID != b.ID {
		t.Fatalf("%q vs %q", a.ID, b.ID)
	}
}

func TestRunRefusesBadOutcomes(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "scan.src")
	_ = os.WriteFile(src, []byte(strings.Split(goodScan, "\n")[0]+"\n"), 0o600) // no summary
	cases := map[string]string{
		"the scanner fails":     "echo boom >&2\nexit 3\n",
		"it writes no file":     "exit 0\n",
		"it writes half a scan": "cp '" + src + "' \"$out\"\n",
		"it writes garbage":     "echo garbage > \"$out\"\n",
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := Exec{Binary: fakeScanner(t, body)}.Run(context.Background(), creds)
			if !errors.Is(err, ErrIncomplete) {
				t.Fatalf("got %v", err)
			}
		})
	}
}

func TestRunStopsAScanThatTakesTooLong(t *testing.T) {
	start := time.Now()
	_, err := Exec{Binary: fakeScanner(t, "sleep 30\n"), Timeout: 300 * time.Millisecond}.Run(context.Background(), creds)
	if !errors.Is(err, ErrIncomplete) || time.Since(start) > 10*time.Second {
		t.Fatalf("err=%v after %s", err, time.Since(start))
	}
}

func TestRunStopsWhenCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(200 * time.Millisecond); cancel() }()
	start := time.Now()
	if _, err := (Exec{Binary: fakeScanner(t, "sleep 30\n")}).Run(ctx, creds); err == nil || time.Since(start) > 10*time.Second {
		t.Fatalf("err=%v after %s", err, time.Since(start))
	}
}

func TestErrorsNeverContainCredentials(t *testing.T) {
	bin := fakeScanner(t, "echo \"AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY\" >&2\nexit 1\n")
	_, err := Exec{Binary: bin}.Run(context.Background(), creds)
	if err == nil || strings.Contains(err.Error(), "testsecretvalue") || strings.Contains(err.Error(), "testtokenvalue") {
		t.Fatalf("the error must not carry the scanner's stderr or any secret: %v", err)
	}
}
