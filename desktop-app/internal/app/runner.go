package app

import (
	"context"
	"sync"

	"github.com/datafy-io/datafy-tools/desktop-app/internal/scanner"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/sso"
)

// LazyRunner finds (downloading and verifying if needed) the scanner on first use, so starting the app is instant and
// the download happens while the person is already looking at "scanning". A failed download is retried next time.
type LazyRunner struct {
	Fetcher scanner.Fetcher
	Log     func(string)

	mu   sync.Mutex
	exec *scanner.Exec
}

func (l *LazyRunner) Run(ctx context.Context, creds sso.Credentials) (scanner.Scan, error) {
	l.mu.Lock()
	if l.exec == nil {
		bin, err := l.Fetcher.Ensure(ctx)
		if err != nil {
			l.mu.Unlock()
			return scanner.Scan{}, err
		}
		l.exec = &scanner.Exec{Binary: bin, Log: l.Log}
	}
	e := l.exec
	l.mu.Unlock()
	return e.Run(ctx, creds)
}
