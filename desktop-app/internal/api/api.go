// Package api is the local HTTP interface the Datafy page uses. It listens on 127.0.0.1 only and treats every
// request as hostile until it has passed, in order:
//
//  1. Host: must be this machine on this port (defeats DNS rebinding).
//  2. Origin: must be the one origin the app was launched for, and on the build's allowlist.
//  3. Secret: the nonce from the launch link, sent in X-Datafy-Nonce (so another page, even on an allowed origin, or
//     another program on the machine, cannot take over a session it did not start).
//
// Nothing here ever returns credentials or tokens: only the session's View and the scan the scanner produced.
package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"strconv"
	"sync"

	"github.com/datafy-io/datafy-tools/desktop-app/internal/protocol"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/scanner"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/session"
	"github.com/datafy-io/datafy-tools/desktop-app/internal/sso"
)

// Session is what the API needs from the running session.
type Session interface {
	State() session.View
	Latest() (scanner.Scan, bool)
	SignIn(session.SignInParams) error
	Roles(accountID string) ([]string, error)
	Select(accountID, role string) error
	ScanNow()
	SignOut()
}

type Deps struct {
	Session  Session
	Profiles func() ([]sso.Profile, error)
	// Allowed decides which origins may use the app at all (config.IsAllowedOrigin in production).
	Allowed func(origin string) bool
	Port    int
	Version string
	// Quit stops the app. Touch is told about each authorised request, for the idle timer. Both optional.
	Quit  func()
	Touch func()
	Log   func(format string, args ...any)
}

type Server struct {
	d Deps

	mu      sync.Mutex
	origin  string
	nonce   string
	bound   bool
	handler http.Handler
}

const maxBody = 4 << 10

type ctxKey struct{}

// secretOK is whether the request carried the right launch secret (only health uses it).
func secretOK(r *http.Request) bool { ok, _ := r.Context().Value(ctxKey{}).(bool); return ok }

func New(d Deps) *Server {
	if d.Log == nil {
		d.Log = func(string, ...any) {}
	}
	s := &Server{d: d}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /internal/open", s.open)
	mux.HandleFunc("GET /v1/health", s.guard(false, s.health))
	mux.HandleFunc("GET /v1/state", s.guard(true, s.state))
	mux.HandleFunc("GET /v1/profiles", s.guard(true, s.profiles))
	mux.HandleFunc("POST /v1/signin", s.guard(true, s.signin))
	mux.HandleFunc("GET /v1/accounts/{id}/roles", s.guard(true, s.roles))
	mux.HandleFunc("POST /v1/select", s.guard(true, s.selectRole))
	mux.HandleFunc("POST /v1/scan/now", s.guard(true, s.scanNow))
	mux.HandleFunc("GET /v1/scan", s.guard(true, s.scan))
	mux.HandleFunc("POST /v1/signout", s.guard(true, s.signout))
	mux.HandleFunc("POST /v1/quit", s.guard(true, s.quit))
	// Preflights are answered by the same gate: allowed origin + localhost host, no secret (browsers cannot send it).
	// Handled here rather than as a mux route, so an unknown path is still a 404 for every method.
	s.handler = s.logged(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			s.preflight(w, r)
			return
		}
		mux.ServeHTTP(w, r)
	}))
	return s
}

func (s *Server) Handler() http.Handler { return s.handler }

// Bind makes origin/nonce the one page allowed to drive the app. A new launch replaces the previous one.
func (s *Server) Bind(l protocol.Launch) {
	s.mu.Lock()
	s.origin, s.nonce, s.bound = l.Origin, l.Nonce, true
	s.mu.Unlock()
}

// --- plumbing ------------------------------------------------------------------------------------------------

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(c int) { w.status = c; w.ResponseWriter.WriteHeader(c) }

// logged records method, path and status only. Never headers, bodies or query strings: the nonce travels in a header.
func (s *Server) logged(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sw := &statusWriter{ResponseWriter: w, status: 200}
		next.ServeHTTP(sw, r)
		s.d.Log("%s %s -> %d", r.Method, r.URL.Path, sw.status)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]string{"error": code, "message": msg})
}

func (s *Server) hostOK(r *http.Request) bool {
	h := r.Host
	return h == net.JoinHostPort("127.0.0.1", strconv.Itoa(s.d.Port)) || h == net.JoinHostPort("localhost", strconv.Itoa(s.d.Port))
}

func (s *Server) cors(w http.ResponseWriter, origin string) {
	h := w.Header()
	h.Set("Access-Control-Allow-Origin", origin)
	h.Set("Vary", "Origin")
	// Chrome's Private Network Access: a public https page may only reach 127.0.0.1 if the server says it may.
	h.Set("Access-Control-Allow-Private-Network", "true")
	h.Set("Access-Control-Expose-Headers", "ETag, X-Scan-Finished-At")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
}

func (s *Server) preflight(w http.ResponseWriter, r *http.Request) {
	origin := r.Header.Get("Origin")
	if !s.hostOK(r) || origin == "" || !s.d.Allowed(origin) {
		fail(w, http.StatusForbidden, "forbidden", "not allowed")
		return
	}
	s.cors(w, origin)
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "content-type, x-datafy-nonce, if-none-match")
	w.Header().Set("Access-Control-Max-Age", "600")
	w.WriteHeader(http.StatusNoContent)
}

// guard enforces host, origin and (when needSecret) the launch secret before the handler runs.
func (s *Server) guard(needSecret bool, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.hostOK(r) {
			fail(w, http.StatusForbidden, "forbidden_host", "not allowed")
			return
		}
		origin := r.Header.Get("Origin")
		if origin == "" || !s.d.Allowed(origin) {
			fail(w, http.StatusForbidden, "forbidden_origin", "not allowed")
			return
		}
		s.mu.Lock()
		bound, boundOrigin, nonce := s.bound, s.origin, s.nonce
		s.mu.Unlock()
		matched := bound && origin == boundOrigin &&
			subtle.ConstantTimeCompare([]byte(r.Header.Get("X-Datafy-Nonce")), []byte(nonce)) == 1
		if needSecret && !matched {
			code := "bad_secret"
			if !bound {
				code = "not_launched"
			}
			s.cors(w, origin) // so the page can read why, and relaunch
			fail(w, http.StatusForbidden, code, "this page did not start the running app: open it again with Connect")
			return
		}
		if needSecret && s.d.Touch != nil {
			s.d.Touch()
		}
		s.cors(w, origin)
		// health is the only route that answers without the secret, and it only says whether the secret matches.
		h(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, matched)))
	}
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBody)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			fail(w, http.StatusRequestEntityTooLarge, "too_large", "request too large")
		} else {
			fail(w, http.StatusBadRequest, "bad_request", "could not read the request")
		}
		return false
	}
	return true
}

// --- endpoints -----------------------------------------------------------------------------------------------

// open is how a second launch hands its link to an app that is already running. It accepts no browser request at all:
// a browser always sends an Origin header on a cross-origin POST, so a page cannot reach it.
func (s *Server) open(w http.ResponseWriter, r *http.Request) {
	if !s.hostOK(r) {
		fail(w, http.StatusForbidden, "forbidden_host", "not allowed")
		return
	}
	if r.Header.Get("Origin") != "" {
		fail(w, http.StatusForbidden, "forbidden_origin", "not allowed")
		return
	}
	var body struct {
		Origin string `json:"origin"`
		Nonce  string `json:"nonce"`
	}
	if !decode(w, r, &body) {
		return
	}
	if !protocol.ValidOrigin(body.Origin) || !s.d.Allowed(body.Origin) || !protocol.ValidNonce(body.Nonce) {
		fail(w, http.StatusBadRequest, "bad_request", "not a valid launch")
		return
	}
	s.Bind(protocol.Launch{Origin: body.Origin, Nonce: body.Nonce})
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	bound := s.bound
	s.mu.Unlock()
	writeJSON(w, 200, map[string]any{
		"ok": true, "version": s.d.Version, "bound": bound,
		"sessionMatch": secretOK(r),
	})
}

func (s *Server) state(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, s.d.Session.State())
}

func (s *Server) profiles(w http.ResponseWriter, r *http.Request) {
	ps, err := s.d.Profiles()
	if err != nil {
		s.d.Log("reading AWS profiles: %v", err)
		ps = nil
	}
	if ps == nil {
		ps = []sso.Profile{}
	}
	writeJSON(w, 200, map[string]any{"profiles": ps})
}

func (s *Server) signin(w http.ResponseWriter, r *http.Request) {
	var b struct {
		StartURL  string `json:"startUrl"`
		Region    string `json:"region"`
		AccountID string `json:"accountId"`
		Role      string `json:"role"`
	}
	if !decode(w, r, &b) {
		return
	}
	if err := s.d.Session.SignIn(session.SignInParams{StartURL: b.StartURL, Region: b.Region, AccountID: b.AccountID, Role: b.Role}); err != nil {
		if errors.Is(err, session.ErrBadInput) {
			fail(w, http.StatusBadRequest, "bad_input", err.Error())
		} else {
			fail(w, http.StatusConflict, "unavailable", err.Error())
		}
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]bool{"started": true})
}

func (s *Server) roles(w http.ResponseWriter, r *http.Request) {
	roles, err := s.d.Session.Roles(r.PathValue("id"))
	switch {
	case errors.Is(err, session.ErrBadInput):
		fail(w, http.StatusBadRequest, "bad_input", "that is not an account ID")
	case err != nil:
		fail(w, http.StatusConflict, "unavailable", "could not list the roles: sign in first")
	default:
		if roles == nil {
			roles = []string{}
		}
		writeJSON(w, 200, map[string]any{"roles": roles})
	}
}

func (s *Server) selectRole(w http.ResponseWriter, r *http.Request) {
	var b struct {
		AccountID string `json:"accountId"`
		Role      string `json:"role"`
	}
	if !decode(w, r, &b) {
		return
	}
	if err := s.d.Session.Select(b.AccountID, b.Role); err != nil {
		if errors.Is(err, session.ErrBadInput) {
			fail(w, http.StatusBadRequest, "bad_input", err.Error())
		} else {
			fail(w, http.StatusConflict, "unavailable", err.Error())
		}
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]bool{"started": true})
}

func (s *Server) scanNow(w http.ResponseWriter, r *http.Request) {
	s.d.Session.ScanNow()
	writeJSON(w, http.StatusAccepted, map[string]bool{"requested": true})
}

func (s *Server) scan(w http.ResponseWriter, r *http.Request) {
	sc, ok := s.d.Session.Latest()
	if !ok {
		fail(w, http.StatusNotFound, "no_scan", "no scan has finished yet")
		return
	}
	etag := `"` + sc.ID + `"`
	w.Header().Set("ETag", etag)
	w.Header().Set("X-Scan-Finished-At", sc.FinishedAt.UTC().Format("2006-01-02T15:04:05Z"))
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(sc.Data)
}

func (s *Server) signout(w http.ResponseWriter, r *http.Request) {
	s.d.Session.SignOut()
	writeJSON(w, 200, map[string]bool{"signedOut": true})
}

func (s *Server) quit(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusAccepted, map[string]bool{"quitting": true})
	if s.d.Quit != nil {
		go s.d.Quit()
	}
}
