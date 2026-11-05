// Command datafy-discovery is the Datafy Discovery app. A Datafy page starts it with a datafy-discovery:// link; it signs
// the person in to AWS, scans their organization read-only every 30 seconds, and serves the result to that page on
// 127.0.0.1. Nothing is sent to Datafy.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/datafy-io/datafy-tools/desktop-app/internal/app"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/browser"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/config"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/protocol"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/scanner"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/session"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/sso"
)

func main() {
	version := flag.Bool("version", false, "print the version and exit")
	port := flag.Int("port", config.DefaultPort, "local port (the Datafy page looks for the default)")
	scannerPath := flag.String("scanner", "", "use this scanner binary instead of the pinned release (development only; skips the checksum)")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Datafy Discovery %s\n\nThis app is started by the Datafy page: press Connect there.\nUsage: datafy-discovery [flags] %s://open?origin=...&nonce=...\n\n", config.Version, config.Scheme)
		flag.PrintDefaults()
	}
	flag.Parse()
	if *version {
		fmt.Println(config.Version)
		return
	}
	if flag.NArg() != 1 {
		flag.Usage()
		os.Exit(2)
	}

	logger := log.New(os.Stderr, "", log.LstdFlags)
	cacheDir, err := scanner.DefaultCacheDir()
	if err != nil {
		logger.Fatalf("no place to keep the scanner: %v", err)
	}
	logf := func(format string, args ...any) { logger.Printf(format, args...) }

	cfg := app.Config{
		Port: *port, Version: config.Version, Allowed: config.IsAllowedOrigin,
		NewSSO:    func(region string) session.SSO { return sso.New(region) },
		Runner:    &app.LazyRunner{Fetcher: scanner.Fetcher{Override: *scannerPath, CacheDir: cacheDir}, Log: func(s string) { logger.Printf("scanner: %s", s) }},
		OpenURL:   browser.Open,
		Profiles:  func() ([]sso.Profile, error) { return sso.LoadProfiles(sso.ConfigPath()) },
		IdleLimit: config.IdleLimit, Interval: config.ScanInterval, MinGap: config.MinScanGap,
		Log: logf,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := app.Run(ctx, cfg, flag.Arg(0)); err != nil {
		switch {
		case errors.Is(err, protocol.ErrInvalid):
			logger.Printf("refusing to start: that is not a valid Datafy launch link")
		default:
			logger.Printf("%v", err)
		}
		os.Exit(1)
	}
}
