package scanner

import (
	"fmt"

	"github.com/datafy-io/datafy-tools/desktop-app/internal/config"
)

// Asset is one published scanner binary and the SHA-256 it must have.
type Asset struct {
	Name   string
	SHA256 string
}

// pins mirrors datafy-tools/plugins/datafy-aws-explorer/scanner.lock.json and the Datafy page's lib/commands.ts.
// The release and every checksum are pinned, so what runs is exactly what Datafy published. Bump all three
// together, and re-verify each value against the real asset.
var pins = map[string]Asset{
	"darwin/arm64":  {"discovery-aws-darwin-arm64", "964b9c8e86a537af77d0c3b17517eca803aebe43057459787e29bde7eb002fb8"},
	"darwin/amd64":  {"discovery-aws-darwin-amd64", "db0b7a41324d2f197fbbd2b08aedda8fca16072ed51a86a8950d7db60f986c77"},
	"linux/amd64":   {"discovery-aws-linux-amd64", "b58450b450577cff08a11a3da621071c278e92954afc350e9ef1b6ff61424a94"},
	"linux/arm64":   {"discovery-aws-linux-arm64", "998473d791b327c90b037145e9f83833dc437087a282d029a7c14f598c66ea99"},
	"windows/amd64": {"discovery-aws-windows-amd64.exe", "8c1340f6faf2db295e79775b918c7876bdb00c02de80d7f386c297858ec877dc"},
	"windows/arm64": {"discovery-aws-windows-arm64.exe", "05d9173d70583f425e038c4b1ca5bb74b62e354edaaeb036e6fe916ca04fe6fa"},
}

// ReleaseBaseURL is where the pinned release lives.
var ReleaseBaseURL = "https://github.com/datafy-io/datafy-tools/releases/download/" + config.ScannerRelease + "/"

// AssetFor returns the pinned binary for an OS and CPU.
func AssetFor(goos, goarch string) (Asset, error) {
	a, ok := pins[goos+"/"+goarch]
	if !ok {
		return Asset{}, fmt.Errorf("there is no discovery scanner for %s/%s", goos, goarch)
	}
	return a, nil
}

// Pins returns every pinned asset (for tests and diagnostics).
func Pins() map[string]Asset {
	out := make(map[string]Asset, len(pins))
	for k, v := range pins {
		out[k] = v
	}
	return out
}
