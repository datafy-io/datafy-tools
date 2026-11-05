// Command demoapp runs the REAL app (real HTTP API, real session, real SSO client) against a fake AWS Identity Center and a
// fake scanner, with a small control server that plays the human: it "launches" the app, approves or expires the sign-in,
// and crashes the app. For testing the Datafy page in a real browser without AWS. Not shipped.
//
//	demoapp -origin http://localhost:3100 -scan /path/to/discovery.jsonl
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"sync"
	"time"

	"github.com/datafy-io/datafy-tools/desktop-app/internal/app"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/scanner"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/session"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/sso"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/testutil/fakeidc"
)

// fixtureRunner serves a fixed scan, stamping the summary with the current time so each scan looks new.
type fixtureRunner struct {
	data  []byte
	mu    sync.Mutex
	count int
}

func (r *fixtureRunner) Run(ctx context.Context, c sso.Credentials) (scanner.Scan, error) {
	r.mu.Lock()
	r.count++
	n := r.count
	r.mu.Unlock()
	select {
	case <-time.After(400 * time.Millisecond):
	case <-ctx.Done():
		return scanner.Scan{}, ctx.Err()
	}
	lines := bytes.Split(bytes.TrimSpace(r.data), []byte("\n"))
	var sum map[string]any
	_ = json.Unmarshal(lines[len(lines)-1], &sum)
	now := time.Now().UTC().Format(time.RFC3339)
	sum["scanned_at"] = now
	last, _ := json.Marshal(sum)
	lines[len(lines)-1] = last
	data := append(bytes.Join(lines, []byte("\n")), '\n')
	s, err := scanner.Parse(data)
	if err != nil {
		return scanner.Scan{}, err
	}
	return scanner.Scan{Data: data, Summary: s, ID: fmt.Sprintf("demo-%d", n), FinishedAt: time.Now()}, nil
}

func main() {
	origin := flag.String("origin", "http://localhost:3100", "the page's origin")
	scanPath := flag.String("scan", "", "a scan file to serve (JSONL, summary last)")
	interval := flag.Duration("interval", 8*time.Second, "time between scans")
	appPort := flag.Int("port", 47615, "app port")
	ctlPort := flag.Int("control", 47616, "control port")
	flag.Parse()
	data, err := os.ReadFile(*scanPath)
	if err != nil || len(data) == 0 {
		log.Fatalf("need -scan: %v", err)
	}
	idc := fakeidc.NewStandalone()
	idc.Accounts = []map[string]string{{"accountId": "327744850861", "accountName": "Datafy (management)"}, {"accountId": "325806006306", "accountName": "development"}}
	idc.Roles = map[string][]string{"327744850861": {"AdministratorAccess", "ReadOnlyAccess"}, "325806006306": {"ReadOnlyAccess"}}
	runner := &fixtureRunner{data: data}

	var mu sync.Mutex
	var cancel context.CancelFunc
	running := false

	cfg := func(onListen func(int)) app.Config {
		return app.Config{
			Port: *appPort, Version: "demo", Allowed: func(o string) bool { return o == *origin },
			NewSSO: func(region string) session.SSO {
				return sso.New(region, sso.WithEndpoints(idc.URL, idc.URL),
					sso.WithClock(time.Now, func(ctx context.Context, d time.Duration) error { time.Sleep(300 * time.Millisecond); return ctx.Err() }))
			},
			Runner: runner, OpenURL: func(string) error { return nil },
			Profiles: func() ([]sso.Profile, error) {
				return []sso.Profile{{Name: "management", StartURL: "https://d-906782a959.awsapps.com/start", Region: "us-east-1"}}, nil
			},
			Interval: *interval, MinGap: time.Second, IdleLimit: 2 * time.Hour, OnListen: onListen,
			Log: func(f string, a ...any) { log.Printf(f, a...) },
		}
	}
	link := func(origin, nonce string) string {
		return "datafy-discovery://open?origin=" + url.QueryEscape(origin) + "&nonce=" + nonce
	}

	launch := func(nonce string) error {
		mu.Lock()
		defer mu.Unlock()
		if running { // a second launch hands the link to the running app, exactly like the real one
			return app.Run(context.Background(), cfg(nil), link(*origin, nonce))
		}
		ctx, c := context.WithCancel(context.Background())
		cancel, running = c, true
		up := make(chan int, 1)
		go func() {
			err := app.Run(ctx, cfg(func(p int) { up <- p }), link(*origin, nonce))
			mu.Lock()
			running = false
			mu.Unlock()
			log.Printf("app stopped: %v", err)
		}()
		select {
		case <-up:
			return nil
		case <-time.After(3 * time.Second):
			return fmt.Errorf("the app did not start")
		}
	}

	mux := http.NewServeMux()
	cors := func(h http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "*")
			if r.Method == http.MethodOptions {
				w.WriteHeader(204)
				return
			}
			h(w, r)
		}
	}
	mux.HandleFunc("/launch", cors(func(w http.ResponseWriter, r *http.Request) {
		if err := launch(r.URL.Query().Get("nonce")); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		fmt.Fprintln(w, "launched")
	}))
	mux.HandleFunc("/approve", cors(func(w http.ResponseWriter, r *http.Request) { idc.Approve(); fmt.Fprintln(w, "approved") }))
	mux.HandleFunc("/revoke", cors(func(w http.ResponseWriter, r *http.Request) { idc.Revoke(); fmt.Fprintln(w, "revoked") }))
	mux.HandleFunc("/restore", cors(func(w http.ResponseWriter, r *http.Request) { idc.Restore(); fmt.Fprintln(w, "restored") }))
	mux.HandleFunc("/kill", cors(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		if cancel != nil {
			cancel()
		}
		mu.Unlock()
		fmt.Fprintln(w, "killed")
	}))
	mux.HandleFunc("/status", cors(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		fmt.Fprintf(w, `{"running":%v,"credentialCalls":%d,"scans":%d}`, running, idc.CredentialCalls(), runner.count)
	}))
	log.Printf("demo control on 127.0.0.1:%d; the app will listen on %d for %s once launched", *ctlPort, *appPort, *origin)
	log.Fatal(http.ListenAndServe(fmt.Sprintf("127.0.0.1:%d", *ctlPort), mux))
}
