package scanner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/datafy-io/datafy-tools/desktop-app/internal/config"
)

// ErrChecksum means a downloaded or cached scanner did not match its pinned SHA-256. It is never run.
var ErrChecksum = errors.New("the discovery scanner did not match its expected checksum, so it was not run")

// Fetcher finds the pinned scanner on disk, downloading it first if needed.
type Fetcher struct {
	// Override, if set, is used as-is instead of the pinned release. For development only: it skips the checksum.
	Override string
	CacheDir string
	BaseURL  string
	Client   *http.Client
	GOOS     string
	GOARCH   string
}

// DefaultCacheDir is where downloaded scanners are kept.
func DefaultCacheDir() (string, error) {
	d, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "DatafyDiscovery", "scanner"), nil
}

func sum(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// Ensure returns the path of a scanner that is safe to run.
func (f Fetcher) Ensure(ctx context.Context) (string, error) {
	if f.Override != "" {
		return f.Override, nil
	}
	goos, goarch := f.GOOS, f.GOARCH
	if goos == "" {
		goos, goarch = runtime.GOOS, runtime.GOARCH
	}
	asset, err := AssetFor(goos, goarch)
	if err != nil {
		return "", err
	}
	dir := filepath.Join(f.CacheDir, config.ScannerRelease)
	dst := filepath.Join(dir, asset.Name)

	// A cached copy is trusted only if it still matches: it could have been replaced since it was downloaded.
	if got, err := sum(dst); err == nil && got == asset.SHA256 {
		return dst, nil
	}
	_ = os.Remove(dst)

	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	base := f.BaseURL
	if base == "" {
		base = ReleaseBaseURL
	}
	client := f.Client
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Minute}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(base, "/")+"/"+asset.Name, nil)
	if err != nil {
		return "", err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("downloading the discovery scanner: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("downloading the discovery scanner: HTTP %d", resp.StatusCode)
	}

	tmp, err := os.CreateTemp(dir, asset.Name+".part-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	h := sha256.New()
	if _, err := io.Copy(io.MultiWriter(tmp, h), resp.Body); err != nil {
		tmp.Close()
		return "", fmt.Errorf("downloading the discovery scanner: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if hex.EncodeToString(h.Sum(nil)) != asset.SHA256 {
		return "", ErrChecksum
	}
	if err := os.Chmod(tmp.Name(), 0o700); err != nil {
		return "", err
	}
	if err := os.Rename(tmp.Name(), dst); err != nil {
		return "", err
	}
	return dst, nil
}
