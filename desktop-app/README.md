# Datafy Discovery (desktop app)

A small background app that lets a Datafy web page show a customer's AWS estate **without pasting anything**.

The customer installs it once. After that, pressing **Connect** in the Datafy page opens it through a
`datafy-discovery://` link, the AWS SSO sign-in opens in their browser, and the app scans their whole organization
read-only every 30 seconds and serves the result to that page on `127.0.0.1`.

**Nothing is sent to Datafy.** The app talks only to AWS (to sign in and to scan) and, once, to GitHub (to download the
pinned scanner). AWS credentials never leave the app: the page only ever receives scan results.

```
 Datafy page ── datafy-discovery://open?origin=…&nonce=… ──▶ OS ──▶ app (127.0.0.1:47615)
      │                                                                  │
      │   GET /v1/state, POST /v1/signin, GET /v1/scan   (origin + secret) │  AWS IAM Identity Center (sign in)
      └──────────────────────────────────────────────────────────────────▶│  discovery scanner (read-only scan)
                                                                          ▼
                                                                      your AWS org
```

## Try it yourself (macOS, from source)

This is a development preview: it is unsigned and builds for the Mac you build it on. Signed installers come later.

**You need:** Go 1.22+, the AWS IAM Identity Center (SSO) start URL for your organization (your admin can give it to you,
or it is already in `~/.aws/config` as an `sso_start_url`), and the Datafy frontend running locally
(`pnpm` 9, in `frontend-mono`).

1. **Build and register the app** (this also registers the `datafy-discovery://` link with macOS):
   ```bash
   cd desktop-app
   ./packaging/macos/build-app.sh --dev     # --dev also trusts http://localhost:3000
   ```
2. **Start the Datafy frontend** from the `feat/discovery-landing-page` branch of `frontend-mono`:
   ```bash
   cd packages/frontend-app && npx vite     # http://localhost:3000
   ```
3. **Open Discovery** in the sidebar and press **Connect**. Your browser asks once to open *Datafy Discovery*; choose
   Open. If Chrome asks to allow access to devices on your local network, allow it.
4. **Sign in** on the AWS page that opens (confirm the code shown), then choose your **management account** and a role.
   The scan starts, and the page refreshes every 30 seconds.

Use the management account and a role that can read EC2 and Organizations (for example `ReadOnlyAccess`); the scanner
reaches member accounts the same way the AWS Explorer plugin does.

**Stopping and removing:** press *Stop* on the page, or run `./packaging/macos/uninstall.sh`. The app also quits by itself
after 8 hours idle.

**If something goes wrong:** the log is `~/Library/Logs/DatafyDiscovery.log`. It records only the method, path and status
of each request, never any data. Common causes: the app is not built (run step 1 again), the page is on a different
address than the build trusts (the `--dev` build trusts only `http://localhost:3000`), or your SSO sign-in expired
(press *Sign in again*; the last scan stays on screen).

**Windows and Linux:** `packaging/windows` and `packaging/linux` exist but have never been run. Treat them as untested.

**Privacy:** nothing is sent to Datafy. The app talks only to AWS and, once, to GitHub to download the pinned scanner.

## What it is made of

| Package | Job |
|---|---|
| `internal/sso` | IAM Identity Center sign-in (device flow), account/role listing, fresh role credentials. Reads SSO profiles from `~/.aws/config` (SSO settings only). |
| `internal/scanner` | Downloads the **pinned, checksum-verified** discovery scanner and runs it with the credentials in a minimal environment. Validates its output before accepting it. |
| `internal/session` | The state machine: sign in → choose account/role → scan every 30 s. Keeps the last complete scan through failures and expired sign-ins. |
| `internal/api` | The localhost HTTP API and its gate: Host, then Origin, then the launch secret. |
| `internal/protocol`, `internal/browser`, `internal/config` | Launch-link parsing, opening the AWS page safely, build-time settings. |
| `internal/app` | Wires it together; hands a second launch to the running app; idle shutdown. |

The scanner is the same release the AWS Explorer plugin and the Datafy page use, run as a subprocess rather than
re-implemented, so there is one scanner to keep correct.

## Security properties, and what enforces them

Every row has a test that fails if the behaviour is removed (each was checked by breaking the code on purpose).

| Property | Test |
|---|---|
| Only the origin that launched the app, and only if the build allows it, can use the API | `internal/api`, `internal/config` |
| Requests need the launch secret (the `nonce`); a stale or other page is refused and the session is never touched | `internal/api` |
| DNS rebinding is refused (Host must be `127.0.0.1:port` or `localhost:port`) | `internal/api` |
| The internal "second launch" route cannot be reached from a browser | `internal/api` |
| A launch link from any other origin, or with anything unexpected in it, starts nothing | `internal/protocol`, `internal/app` |
| Listens on loopback only | `internal/app` (and checked live) |
| Credentials and tokens are redacted if printed, never in the API, never in logs, never in error text shown to the page | `internal/sso`, `internal/session`, `internal/api` |
| The scanner runs as exactly the chosen account and role, in a clean environment (no stray `AWS_PROFILE`, keys or endpoints) | `internal/scanner` |
| A tampered or replaced scanner is never run (SHA-256 checked on download and on every reuse) | `internal/scanner` |
| A scan that did not finish never replaces the last good one | `internal/session`, `internal/scanner` |
| A cancelled or timed-out scan really stops, including anything it started | `internal/scanner` |
| The AWS page is opened only if it is an AWS sign-in domain, and never through a shell | `internal/browser` |
| The pinned checksums equal the AWS Explorer plugin's lock file | `internal/scanner` |

## HTTP API (what the Datafy page uses)

All requests: `Origin` = the page's origin, header `X-Datafy-Nonce` = the secret from the launch link.
`/v1/health` answers any allowed origin (so the page can tell the app is installed) and reports `sessionMatch`.

| | |
|---|---|
| `GET /v1/health` | `{ok, version, bound, sessionMatch}` |
| `GET /v1/state` | phase (`idle` · `signing_in` · `choosing` · `scanning` · `waiting` · `needs_signin` · `failed`), `prompt` (`url`, `userCode`), `accounts`, `selected`, `scan`, `nextScanAt`, `problem` |
| `GET /v1/profiles` | SSO profiles from `~/.aws/config`: name, start URL, region, account, role |
| `POST /v1/signin` | `{startUrl, region, accountId?, role?}`: opens the AWS sign-in page |
| `GET /v1/accounts/{id}/roles` | roles in an account |
| `POST /v1/select` | `{accountId, role}`: starts scanning |
| `GET /v1/scan` | the latest complete scan (NDJSON, `ETag`, `X-Scan-Finished-At`); `304` for `If-None-Match` |
| `POST /v1/scan/now`, `/v1/signout`, `/v1/quit` | |

## Develop

```bash
go test -race ./...                       # everything below needs no AWS account
go test -tags live -run Live ./...        # opt-in: real GitHub download + real AWS OIDC (stops at the code; approves nothing)
go test -tags dev ./...                   # the dev build, which also trusts http://localhost:3000
```

### Try it on a Mac (unsigned, built on this machine: no Gatekeeper warning)

```bash
./packaging/macos/build-app.sh --dev     # builds "Datafy Discovery.app" and registers datafy-discovery://
open 'datafy-discovery://open?origin=http%3A%2F%2Flocalhost%3A3000&nonce=0123456789abcdef0123'
curl -H 'Origin: http://localhost:3000' -H 'X-Datafy-Nonce: 0123456789abcdef0123' http://127.0.0.1:47615/v1/state
./packaging/macos/uninstall.sh           # removes it
```

The log is `~/Library/Logs/DatafyDiscovery.log`. Windows and Linux scripts are in `packaging/` and have **not** been run.

## Before this can ship to customers

1. **Confirm the production origin** in `internal/config/origins.go` (currently `https://app.datafy.io`, a placeholder).
2. **Sign it.** macOS needs an Apple Developer ID + notarization; Windows needs a code-signing certificate. Unsigned
   apps work on the machine that built them, but a downloaded one is blocked by Gatekeeper / SmartScreen.
3. **Installers** (pkg/MSI/deb) instead of the dev scripts, published by CI to a release.
4. **Safari** cannot reach `127.0.0.1` from an https page; version 1 targets Chrome, Edge and Firefox.
5. The sign-in is not yet reused from the AWS CLI's cache, so each new app session signs in once (usually one click
   if the browser is already signed in to AWS).
6. Bump `config.ScannerRelease`, `ScannerToolVersion` and `internal/scanner/pins.go` together with the plugin's
   `scanner.lock.json` and the Datafy page's `lib/commands.ts`; a test checks the first two against each other.

## Not verified against real AWS

Everything up to the on-screen sign-in code was exercised against real AWS (`-tags live`). The calls that need an
**approved** sign-in (token exchange, `ListAccounts`, `GetRoleCredentials`) are covered by tests against a fake that speaks
the real wire protocol, but have not run against real AWS because that needs a person to approve the sign-in.
