// Package config holds the app's fixed settings. Nothing here is read from the environment or a file on
// purpose: what the app trusts is decided when it is built, not by whatever is on the machine.
package config

import "time"

const (
	Version = "0.1.0"

	// DefaultPort is where the local API listens, on 127.0.0.1 only. The Datafy page looks for the app here.
	DefaultPort = 47615

	// Scheme is the URL scheme the operating system hands to this app: datafy-discovery://open?...
	Scheme = "datafy-discovery"

	// ScanInterval is how often the scan repeats, measured start to start.
	ScanInterval = 30 * time.Second
	// MinScanGap is the pause after a scan that overran ScanInterval, so AWS is never hammered.
	MinScanGap = 5 * time.Second
	// ScanTimeout bounds a single scan.
	ScanTimeout = 15 * time.Minute

	// IdleLimit is how long the app keeps running with no request from the page.
	IdleLimit = 8 * time.Hour

	// ScannerRelease and ScannerToolVersion pin the discovery scanner this app runs. They mirror
	// datafy-tools/plugins/datafy-aws-explorer/scanner.lock.json and the Datafy page: bump all together.
	ScannerRelease     = "v0.3.1"
	ScannerToolVersion = "0.2.1"
)
