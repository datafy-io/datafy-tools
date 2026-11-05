// Package app starts the Datafy Discovery app: it listens on localhost, binds the page that launched it, and runs the
// session. A second launch does not start a second app: it hands its link to the one already running.
package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/datafy-io/datafy-tools/desktop-app/internal/api"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/config"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/protocol"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/scanner"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/session"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/sso"
)

// Config is everything that varies between the real app and a test. main fills it in with the production values.
type Config struct {
	Port    int
	Version string
	Allowed func(origin string) bool

	NewSSO   func(region string) session.SSO
	Runner   scanner.Runner
	OpenURL  func(url string) error
	Profiles func() ([]sso.Profile, error)

	Interval  time.Duration
	MinGap    time.Duration
	IdleLimit time.Duration

	// OnListen is told the port once the app is accepting requests (tests use port 0).
	OnListen func(port int)
	Log      func(format string, args ...any)
}

// ErrNotOurs means something is already listening on the port, but it is not a Datafy Discovery app.
var ErrNotOurs = errors.New("the port is in use by another program")

// Run handles one launch. If an app is already running it forwards the link to it and returns. Otherwise it becomes
// the app: it serves until ctx is cancelled, the page asks it to quit, or it has been idle for too long.
func Run(ctx context.Context, cfg Config, launchURL string) error {
	if cfg.Log == nil {
		cfg.Log = func(string, ...any) {}
	}
	if cfg.Allowed == nil {
		cfg.Allowed = config.IsAllowedOrigin
	}
	launch, err := protocol.Parse(launchURL, cfg.Allowed)
	if err != nil {
		return err
	}

	ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(cfg.Port)))
	if err != nil {
		return forward(cfg, launch)
	}
	port := ln.Addr().(*net.TCPAddr).Port

	sess := session.New(session.Options{
		NewSSO: cfg.NewSSO, Runner: cfg.Runner, OpenURL: cfg.OpenURL,
		Interval: cfg.Interval, MinGap: cfg.MinGap, Log: cfg.Log,
	})
	defer sess.Close()

	runCtx, stop := context.WithCancel(ctx)
	defer stop()

	idle := newIdle(cfg.IdleLimit, stop)
	defer idle.stop()

	srv := api.New(api.Deps{
		Session: sess, Profiles: cfg.Profiles, Allowed: cfg.Allowed, Port: port, Version: cfg.Version,
		Quit: stop, Touch: idle.touch, Log: cfg.Log,
	})
	srv.Bind(launch)

	httpSrv := &http.Server{Handler: srv.Handler(), ReadHeaderTimeout: 10 * time.Second}
	done := make(chan error, 1)
	go func() { done <- httpSrv.Serve(ln) }()
	if cfg.OnListen != nil {
		cfg.OnListen(port)
	}
	cfg.Log("listening on 127.0.0.1:%d for %s", port, launch.Origin)

	select {
	case <-runCtx.Done():
	case err := <-done:
		return err
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = httpSrv.Shutdown(shutdown)
	return nil
}

// forward hands the link to the app that is already running. That app only accepts it from a request with no Origin
// header, which no web page can send.
func forward(cfg Config, l protocol.Launch) error {
	body, _ := json.Marshal(map[string]string{"origin": l.Origin, "nonce": l.Nonce})
	c := &http.Client{Timeout: 5 * time.Second}
	resp, err := c.Post("http://"+net.JoinHostPort("127.0.0.1", strconv.Itoa(cfg.Port))+"/internal/open", "application/json", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("%w (%v)", ErrNotOurs, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("%w (it answered %d)", ErrNotOurs, resp.StatusCode)
	}
	cfg.Log("an app is already running; handed it the new link")
	return nil
}

// idle shuts the app down when nothing has used it for a long time.
type idleTimer struct {
	mu sync.Mutex
	t  *time.Timer
	d  time.Duration
}

func newIdle(d time.Duration, onIdle func()) *idleTimer {
	i := &idleTimer{d: d}
	if d > 0 {
		i.t = time.AfterFunc(d, onIdle)
	}
	return i
}

func (i *idleTimer) touch() {
	i.mu.Lock()
	defer i.mu.Unlock()
	if i.t != nil {
		i.t.Reset(i.d)
	}
}

func (i *idleTimer) stop() {
	i.mu.Lock()
	defer i.mu.Unlock()
	if i.t != nil {
		i.t.Stop()
	}
}
