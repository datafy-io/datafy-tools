// Package fakeidc is an AWS IAM Identity Center (OIDC + portal) server that speaks the real wire protocol, for tests.
// The real SDK client talks to it unchanged, so a passing test means the request and response shapes are right.
package fakeidc

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

type Server struct {
	URL      string
	Bearer   string
	Accounts []map[string]string
	Roles    map[string][]string

	mu       sync.Mutex
	approved bool
	Polls    int
	Creds    int
	// StartURLs records every start URL the app asked to sign in to.
	StartURLs []string
	closer    func()
	// Revoked makes the portal reject the bearer token, as if the sign-in had expired.
	Revoked bool
}

// Approve is the person finishing the sign-in in the browser: until it is called, polling answers "pending".
func (s *Server) Approve() { s.mu.Lock(); s.approved = true; s.mu.Unlock() }

func (s *Server) Revoke() { s.mu.Lock(); s.Revoked = true; s.mu.Unlock() }

// Restore undoes Revoke and un-approves, as if the person signed in afresh.
func (s *Server) Restore() { s.mu.Lock(); s.Revoked = false; s.approved = false; s.mu.Unlock() }

func (s *Server) CredentialCalls() int { s.mu.Lock(); defer s.mu.Unlock(); return s.Creds }

// New is for tests: the server is closed when the test ends.
func New(t *testing.T) *Server {
	s := newServer()
	t.Cleanup(s.closer)
	return s
}

// NewStandalone is for demos outside a test; it runs until the process exits.
func NewStandalone() *Server { return newServer() }

func newServer() *Server {
	s := &Server{Bearer: "bearer-token", Roles: map[string][]string{}}
	writeErr := func(w http.ResponseWriter, status int, typ, code string) {
		w.Header().Set("X-Amzn-Errortype", typ)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": code, "message": typ})
	}
	out := func(w http.ResponseWriter, v any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(v)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/client/register", func(w http.ResponseWriter, r *http.Request) {
		out(w, map[string]any{"clientId": "cid", "clientSecret": "csecret", "clientIdIssuedAt": 1, "clientSecretExpiresAt": 2})
	})
	mux.HandleFunc("/device_authorization", func(w http.ResponseWriter, r *http.Request) {
		var in map[string]any
		_ = json.NewDecoder(r.Body).Decode(&in)
		s.mu.Lock()
		s.StartURLs = append(s.StartURLs, fmt.Sprint(in["startUrl"]))
		s.mu.Unlock()
		out(w, map[string]any{
			"deviceCode": "dcode", "userCode": "ABCD-EFGH", "verificationUri": "https://device.sso.us-east-1.amazonaws.com/",
			"verificationUriComplete": "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH", "expiresIn": 600, "interval": 1,
		})
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		s.Polls++
		ok := s.approved
		s.mu.Unlock()
		if !ok {
			writeErr(w, 400, "AuthorizationPendingException", "authorization_pending")
			return
		}
		out(w, map[string]any{"accessToken": s.Bearer, "tokenType": "Bearer", "expiresIn": 28800})
	})
	portal := func(h http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			s.mu.Lock()
			revoked := s.Revoked
			s.mu.Unlock()
			if revoked || r.Header.Get("X-Amz-Sso_bearer_token") != s.Bearer {
				writeErr(w, 401, "UnauthorizedException", "Session token not found or invalid")
				return
			}
			h(w, r)
		}
	}
	mux.HandleFunc("/assignment/accounts", portal(func(w http.ResponseWriter, r *http.Request) {
		out(w, map[string]any{"accountList": s.Accounts})
	}))
	mux.HandleFunc("/assignment/roles", portal(func(w http.ResponseWriter, r *http.Request) {
		var rl []map[string]string
		id := r.URL.Query().Get("account_id")
		for _, name := range s.Roles[id] {
			rl = append(rl, map[string]string{"roleName": name, "accountId": id})
		}
		out(w, map[string]any{"roleList": rl})
	}))
	mux.HandleFunc("/federation/credentials", portal(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		s.Creds++
		n := s.Creds
		s.mu.Unlock()
		out(w, map[string]any{"roleCredentials": map[string]any{
			"accessKeyId": fmt.Sprintf("ASIAFAKE%d", n), "secretAccessKey": "fakesecretaccesskey", "sessionToken": "fakesessiontoken", "expiration": 1900000000000,
		}})
	}))
	ts := httptest.NewServer(mux)
	s.closer = ts.Close
	s.URL = ts.URL
	return s
}
