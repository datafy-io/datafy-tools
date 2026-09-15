// Datafy Discovery Tool — Azure (Go)
//
// Inventories managed disks, virtual machines, scale sets, snapshots, images
// and backup policies across every subscription in an Azure tenant.
// Read-only, unless --setup-role is used. Safe to run in production.
//
// Output is byte-identical to the Python and bash implementations. Like them,
// this talks to ARM directly and reads the raw JSON rather than going through
// the generated armcompute/armresources packages: the field names in the output
// are then fixed by the api-version this tool pins, not by which SDK release
// happens to be vendored.
//
// Records are built as map[string]any rather than as structs, for the same
// reason. A struct with omitempty would drop the nulls the other two emit, and
// a struct without it would need a pointer for every optional field; maps make
// "absent means null" the default and keep the three implementations honest.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/rand"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
)

// ── Configuration ────────────────────────────────────────────────────────────

const (
	version                = "0.1.0"
	maxSubscriptionWorkers = 20    // subscriptions scanned in parallel
	maxCallWorkers         = 8     // independent ARM calls in flight per subscription
	maxErrorChars          = 400   // keep error strings readable in the output file
	maxPages               = 10000 // nextLink guard — a loop must fail, not spin forever

	// The built-in Reader role. This GUID is the same in every Azure cloud and
	// tenant — built-in role definition ids are global constants.
	readerRoleID = "acdd72a7-3385-48ef-bd42-f606fba81ae7"
)

var (
	armEndpoint = strings.TrimRight(envOr("AZURE_ARM_ENDPOINT", "https://management.azure.com"), "/")
	armScope    = envOr("AZURE_ARM_SCOPE", "")

	// Retry policy, pinned rather than left to the client default so a run is
	// reproducible and this edition rides out a burst the same way the others
	// do. AZURE_MAX_ATTEMPTS counts TOTAL attempts, the first one included.
	maxAttempts      = envInt("AZURE_MAX_ATTEMPTS", 10)
	retryBackoff     = envFloat("AZURE_RETRY_BACKOFF", 0.8)
	retryBackoffMax  = envFloat("AZURE_RETRY_BACKOFF_MAX", 120)
	propagationWait  = envFloat("AZURE_PROPAGATION_TIMEOUT", 300)
	propagationPoll  = envFloat("AZURE_PROPAGATION_POLL", 10)
	retriableStatus  = map[int]bool{408: true, 429: true, 500: true, 502: true, 503: true, 504: true}
	assignmentNSUUID = "6f9d3a1e-0b6c-5f8a-9c2d-4e7b1a3f5c80"
)

// ARM api-versions, pinned so the response shape is reproducible. Each is
// overridable from the environment, and must match the other implementations.
var api = map[string]string{
	"subscriptions":    apiVer("SUBSCRIPTIONS", "2022-12-01"),
	"descendants":      apiVer("DESCENDANTS", "2021-04-01"),
	"disks":            apiVer("DISKS", "2023-04-02"),
	"snapshots":        apiVer("SNAPSHOTS", "2023-04-02"),
	"virtual_machines": apiVer("VIRTUAL_MACHINES", "2023-09-01"),
	"scale_sets":       apiVer("SCALE_SETS", "2023-09-01"),
	"images":           apiVer("IMAGES", "2023-09-01"),
	"rsv_vaults":       apiVer("RSV_VAULTS", "2023-04-01"),
	"rsv_policies":     apiVer("RSV_POLICIES", "2023-02-01"),
	"dp_vaults":        apiVer("DP_VAULTS", "2023-05-01"),
	"dp_policies":      apiVer("DP_POLICIES", "2023-05-01"),
	"role_assignments": apiVer("ROLE_ASSIGNMENTS", "2022-04-01"),
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func apiVer(name, fallback string) string { return envOr("AZURE_API_"+name, fallback) }

func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 1 {
			return n
		}
	}
	return fallback
}

func envFloat(key string, fallback float64) float64 {
	if v := os.Getenv(key); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return fallback
}

// ── Utilities ────────────────────────────────────────────────────────────────

// logf writes progress and diagnostics to stderr.
//
// The tool has one product — the JSONL file named by --output — and stdout is
// left clean for the caller. An operator who redirects stdout must still see
// that subscriptions were skipped.
func logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
}

func nowUTC() string { return time.Now().UTC().Format("2006-01-02T15:04:05Z") }

// armError is an error ARM reported, reduced to the two fields worth recording.
type armError struct {
	Status  int
	Code    string
	Message string
}

func (e *armError) Error() string { return e.Code + ": " + e.Message }

// condense squashes an error into one short line fit for a JSON field.
func condense(err error) string {
	var ae *armError
	text := err.Error()
	if errors.As(err, &ae) {
		text = ae.Code + ": " + ae.Message
	}
	text = strings.Join(strings.Fields(text), " ")
	if len(text) > maxErrorChars {
		text = text[:maxErrorChars]
	}
	return text
}

// resourceGroupOf returns the resource group embedded in an ARM resource id.
//
// Matched case-insensitively: ARM echoes back whatever casing the caller used
// when the resource was created, so "resourcegroups" is as common as
// "resourceGroups" in real tenants.
func resourceGroupOf(id any) any {
	s, ok := id.(string)
	if !ok || s == "" {
		return nil
	}
	parts := strings.Split(strings.Trim(s, "/"), "/")
	for i, part := range parts {
		if strings.EqualFold(part, "resourceGroups") && i+1 < len(parts) {
			return parts[i+1]
		}
	}
	return nil
}

// nameOf returns the trailing name segment of an ARM resource id.
func nameOf(id any) any {
	s, ok := id.(string)
	if !ok || s == "" {
		return nil
	}
	s = strings.TrimRight(s, "/")
	if i := strings.LastIndex(s, "/"); i >= 0 {
		s = s[i+1:]
	}
	if s == "" {
		return nil
	}
	return s
}

// dig walks nested JSON objects safely. ARM omits absent sub-objects entirely.
func dig(obj any, path ...string) any {
	for _, key := range path {
		m, ok := obj.(map[string]any)
		if !ok {
			return nil
		}
		obj = m[key]
		if obj == nil {
			return nil
		}
	}
	return obj
}

// tagsOf returns ARM tags, always an object. Absent and empty are the same here.
func tagsOf(r map[string]any) any {
	if t, ok := r["tags"].(map[string]any); ok {
		return t
	}
	return map[string]any{}
}

// listOf returns a JSON array field, always an array.
func listOf(r map[string]any, key string) any {
	if v, ok := r[key].([]any); ok {
		return v
	}
	return []any{}
}

func asObject(v any) map[string]any {
	if m, ok := v.(map[string]any); ok {
		return m
	}
	return map[string]any{}
}

func asArray(v any) []any {
	if a, ok := v.([]any); ok {
		return a
	}
	return nil
}

// ── ARM client ───────────────────────────────────────────────────────────────

type armClient struct {
	http  *http.Client
	cred  azcore.TokenCredential
	token string // set when AZURE_ACCESS_TOKEN was supplied
	mu    sync.Mutex
	cache azcore.AccessToken
}

func newARMClient(cred azcore.TokenCredential, staticToken string) *armClient {
	return &armClient{
		http:  &http.Client{Timeout: 120 * time.Second, Transport: transport()},
		cred:  cred,
		token: staticToken,
	}
}

// transport returns the HTTP transport, honouring a private CA bundle if one is
// named.
//
// Go on Linux reads SSL_CERT_FILE by itself, but on macOS it uses the platform
// verifier and ignores it — while Python's requests (REQUESTS_CA_BUNDLE) and
// curl (CURL_CA_BUNDLE) honour theirs everywhere. Reading it explicitly keeps
// the three implementations configurable the same way, and is what an operator
// behind a TLS-inspecting proxy needs in order to run this at all.
//
// The bundle is *added* to the system roots rather than replacing them, so
// naming one does not quietly narrow what else the tool will trust.
func transport() *http.Transport {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	path := envOr("AZURE_CA_BUNDLE", os.Getenv("SSL_CERT_FILE"))
	if path == "" {
		return tr
	}
	pem, err := os.ReadFile(path)
	if err != nil {
		logf("  [warn] could not read the CA bundle at %s: %s", path, err)
		return tr
	}
	pool, err := x509.SystemCertPool()
	if err != nil || pool == nil {
		pool = x509.NewCertPool()
	}
	if !pool.AppendCertsFromPEM(pem) {
		logf("  [warn] no certificates found in the CA bundle at %s", path)
		return tr
	}
	tr.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	return tr
}

func (c *armClient) bearer(ctx context.Context) (string, error) {
	if c.token != "" {
		return c.token, nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cache.Token != "" && time.Until(c.cache.ExpiresOn) > time.Minute {
		return c.cache.Token, nil
	}
	tok, err := c.cred.GetToken(ctx, policy.TokenRequestOptions{Scopes: []string{armScope}})
	if err != nil {
		return "", err
	}
	c.cache = tok
	return tok.Token, nil
}

// do performs one ARM request with the pinned retry policy.
//
// Retries the throttling and transient status codes with exponential backoff
// and jitter, honouring Retry-After when ARM sends one — which it does on the
// 429s a tenant-wide scan produces routinely.
func (c *armClient) do(ctx context.Context, method, rawURL string, body any) ([]byte, int, error) {
	var payload []byte
	if body != nil {
		var err error
		if payload, err = json.Marshal(body); err != nil {
			return nil, 0, err
		}
	}

	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		token, err := c.bearer(ctx)
		if err != nil {
			return nil, 0, err
		}

		var reader io.Reader
		if payload != nil {
			reader = strings.NewReader(string(payload))
		}
		req, err := http.NewRequestWithContext(ctx, method, rawURL, reader)
		if err != nil {
			return nil, 0, err
		}
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Accept", "application/json")
		if payload != nil {
			req.Header.Set("Content-Type", "application/json")
		}

		resp, err := c.http.Do(req)
		if err != nil {
			lastErr = err
			if attempt == maxAttempts || ctx.Err() != nil {
				return nil, 0, err
			}
			sleepBackoff(ctx, attempt, "")
			continue
		}

		data, readErr := io.ReadAll(resp.Body)
		retryAfter := resp.Header.Get("Retry-After")
		resp.Body.Close()
		if readErr != nil {
			lastErr = readErr
			if attempt == maxAttempts {
				return nil, resp.StatusCode, readErr
			}
			sleepBackoff(ctx, attempt, retryAfter)
			continue
		}

		if retriableStatus[resp.StatusCode] && attempt < maxAttempts {
			sleepBackoff(ctx, attempt, retryAfter)
			continue
		}
		return data, resp.StatusCode, nil
	}
	return nil, 0, lastErr
}

func sleepBackoff(ctx context.Context, attempt int, retryAfter string) {
	delay := retryBackoff * math.Pow(2, float64(attempt-1))
	if delay > retryBackoffMax {
		delay = retryBackoffMax
	}
	// Jitter, so a fleet of parallel calls does not retry in lockstep.
	delay = delay * (0.5 + rand.Float64()/2)
	if retryAfter != "" {
		if secs, err := strconv.ParseFloat(retryAfter, 64); err == nil && secs > 0 {
			delay = secs
		}
	}
	select {
	case <-time.After(time.Duration(delay * float64(time.Second))):
	case <-ctx.Done():
	}
}

// decode turns an ARM response into a JSON object, or an armError.
func decode(data []byte, status int) (map[string]any, error) {
	var body map[string]any
	parseErr := json.Unmarshal(data, &body)

	if status >= 400 {
		// ARM's documented error envelope is {"error": {"code", "message"}},
		// but some providers answer with the inner object directly and a
		// gateway in front may answer with no JSON at all. Every one of those
		// still has to produce a code and a message.
		errObj := asObject(dig(body, "error"))
		if len(errObj) == 0 {
			errObj = body
		}
		code, _ := errObj["code"].(string)
		if code == "" {
			code = fmt.Sprintf("Http%d", status)
		}
		message, _ := errObj["message"].(string)
		if message == "" {
			message = http.StatusText(status)
			if message == "" {
				message = "no message"
			}
		}
		return nil, &armError{Status: status, Code: code, Message: message}
	}
	if parseErr != nil || body == nil {
		return nil, &armError{Status: status, Code: "InvalidResponse",
			Message: "ARM returned a body that is not JSON"}
	}
	return body, nil
}

func (c *armClient) get(ctx context.Context, path, apiVersion string, params map[string]string) (map[string]any, error) {
	q := url.Values{}
	q.Set("api-version", apiVersion)
	for k, v := range params {
		q.Set(k, v)
	}
	data, status, err := c.do(ctx, http.MethodGet, armEndpoint+path+"?"+q.Encode(), nil)
	if err != nil {
		return nil, err
	}
	return decode(data, status)
}

// list collects every page of an ARM list call, following nextLink.
//
// ARM paginates by handing back an absolute nextLink that already carries its
// own api-version and continuation token, so following it means re-sending it
// verbatim — adding parameters to it is how a paginated scan silently returns
// only its first page.
func (c *armClient) list(ctx context.Context, path, apiVersion string, params map[string]string) ([]any, error) {
	body, err := c.get(ctx, path, apiVersion, params)
	if err != nil {
		return nil, err
	}
	items := asArray(body["value"])
	pages := 1

	for {
		link, _ := body["nextLink"].(string)
		if link == "" {
			return items, nil
		}
		if pages >= maxPages {
			return nil, &armError{Code: "TooManyPages",
				Message: fmt.Sprintf("list did not terminate after %d pages", maxPages)}
		}
		u, parseErr := url.Parse(link)
		if parseErr != nil || (u.Scheme != "http" && u.Scheme != "https") {
			return nil, &armError{Code: "InvalidNextLink",
				Message: "nextLink is not an http(s) URL: " + truncate(link, 120)}
		}
		data, status, doErr := c.do(ctx, http.MethodGet, link, nil)
		if doErr != nil {
			return nil, doErr
		}
		if body, err = decode(data, status); err != nil {
			return nil, err
		}
		items = append(items, asArray(body["value"])...)
		pages++
	}
}

func (c *armClient) put(ctx context.Context, path, apiVersion string, body any) (map[string]any, error) {
	q := url.Values{}
	q.Set("api-version", apiVersion)
	data, status, err := c.do(ctx, http.MethodPut, armEndpoint+path+"?"+q.Encode(), body)
	if err != nil {
		return nil, err
	}
	return decode(data, status)
}

func (c *armClient) delete(ctx context.Context, path, apiVersion string) error {
	q := url.Values{}
	q.Set("api-version", apiVersion)
	data, status, err := c.do(ctx, http.MethodDelete, armEndpoint+path+"?"+q.Encode(), nil)
	if err != nil {
		return err
	}
	if status == 204 {
		return nil
	}
	_, err = decode(data, status)
	return err
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
