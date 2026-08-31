package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
)

type options struct {
	setupRole       bool
	tenant          string
	managementGroup string
	include         string
	exclude         string
	output          string
	showVersion     bool
}

func parseFlags() options {
	var opt options
	flag.BoolVar(&opt.showVersion, "version", false, "Print version and exit")
	flag.BoolVar(&opt.setupRole, "setup-role", false,
		"Assign the built-in Reader role to the signed-in identity at the tenant root management "+
			"group (or at --management-group), wait for it to take effect, scan, then always remove it "+
			"again. Requires permission to create role assignments. Without this flag the tool writes "+
			"nothing and scans with whatever access the identity already has.")
	flag.StringVar(&opt.tenant, "tenant", "", "Limit to subscriptions in this Microsoft Entra tenant")
	flag.StringVar(&opt.managementGroup, "management-group", "",
		"Limit to subscriptions beneath this management group, nested ones included")
	flag.StringVar(&opt.include, "include", "", "Comma-separated subscription IDs to scan (instead of all)")
	flag.StringVar(&opt.exclude, "exclude", "", "Comma-separated subscription IDs to skip")
	flag.StringVar(&opt.output, "output", "", "Output file path (default: discovery_azure_<timestamp>.json)")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr,
			"Datafy Discovery Tool (Azure) v%s — inventories managed disks, virtual machines,\n"+
				"snapshots, images and backup policies across an Azure tenant.\n"+
				"Read-only, unless --setup-role is used. Safe to run in production.\n\n"+
				"Usage:\n", version)
		flag.PrintDefaults()
	}
	flag.Parse()
	return opt
}

func splitIDs(raw string) []string {
	out := []string{}
	for _, part := range strings.Split(raw, ",") {
		if p := strings.TrimSpace(part); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func main() {
	opt := parseFlags()
	if opt.showVersion {
		fmt.Printf("Datafy Discovery Tool (Azure) v%s\n", version)
		return
	}

	if armScope == "" {
		armScope = armEndpoint + "/.default"
	}

	include := splitIDs(opt.include)
	exclude := map[string]bool{}
	for _, id := range splitIDs(opt.exclude) {
		exclude[id] = true
	}

	logf("Datafy Discovery Tool (Azure) v%s", version)
	if armEndpoint != "https://management.azure.com" {
		logf("ARM endpoint:        %s", armEndpoint)
	}

	// Route SIGTERM through the same path as Ctrl+C, so a run killed by a
	// timeout or a supervisor still writes out what it has collected. Which
	// signal arrived is remembered so the process can exit 128+signal: a
	// supervising script has to be able to tell an interrupted run from a clean
	// one, and exiting 0 after an interrupt claims coverage the scan never had.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	interrupted := false
	interruptSignal := int(syscall.SIGINT)
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	go func() {
		sig := <-signals
		if s, ok := sig.(syscall.Signal); ok {
			interruptSignal = int(s)
		}
		interrupted = true
		logf("\nInterrupted — writing out the results collected so far...")
		cancel()
	}()

	client, err := buildClient(opt.tenant)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: could not authenticate to Azure — %s\n\n%s\n", condense(err), signInHelp)
		os.Exit(1)
	}

	// --setup-role is the only path in this tool that writes anything. Whatever
	// happens afterwards, the assignment it created has to come back off.
	var granted []grantedScope
	defer func() { teardownReaderAccess(client, granted) }()

	if opt.setupRole {
		granted, err = setupReaderAccess(ctx, client, opt.tenant, opt.managementGroup)
		if err != nil {
			fmt.Fprintf(os.Stderr,
				"Error: --setup-role could not grant Reader — %s\n\n"+
					"Creating a role assignment needs Owner, User Access Administrator or\n"+
					"Role Based Access Control Administrator at the scope. Assigning at a\n"+
					"tenant root management group additionally needs the Global Administrator\n"+
					"to have elevated access at least once — see README.md, 'Permissions'.\n\n"+
					"Run without --setup-role to scan with the access you already have.\n", condense(err))
			teardownReaderAccess(client, granted)
			granted = nil
			os.Exit(1)
		}
	}

	code := runScan(ctx, client, opt, include, exclude, &interrupted, &interruptSignal)
	teardownReaderAccess(client, granted)
	granted = nil
	os.Exit(code)
}

const signInHelp = `Sign in using one of:
  az login                                     (Azure CLI — simplest)
  az login --tenant <tenant-id>                (a specific tenant)
  export AZURE_CLIENT_ID=... AZURE_TENANT_ID=... AZURE_CLIENT_SECRET=...
                                               (service principal)
  export AZURE_ACCESS_TOKEN=$(az account get-access-token \
           --query accessToken -o tsv)         (a token you already hold)

Running inside Azure Cloud Shell or on a VM with a managed identity needs
no sign-in step at all.`

func buildClient(tenant string) (*armClient, error) {
	if token := os.Getenv("AZURE_ACCESS_TOKEN"); token != "" {
		logf("Auth: using the token in AZURE_ACCESS_TOKEN")
		return newARMClient(nil, token), nil
	}
	opts := &azidentity.DefaultAzureCredentialOptions{}
	if tenant != "" {
		opts.TenantID = tenant
	}
	cred, err := azidentity.NewDefaultAzureCredential(opts)
	if err != nil {
		return nil, err
	}
	return newARMClient(cred, ""), nil
}

// runScan enumerates, scans and writes the output file. Returns the exit code.
func runScan(ctx context.Context, client *armClient, opt options, include []string,
	exclude map[string]bool, interrupted *bool, interruptSignal *int) int {

	tenantHint := ""
	if token, err := client.bearer(ctx); err == nil {
		if claims, cerr := tokenClaims(token); cerr == nil {
			tenantHint, _ = claims["tid"].(string)
		}
	}

	subscriptions, unreachable, scope, err := listSubscriptions(
		ctx, client, opt.tenant, opt.managementGroup, include, exclude, tenantHint)
	if err != nil {
		fmt.Fprintf(os.Stderr,
			"Error: could not determine which subscriptions to scan — %s\n\n"+
				"The identity needs Reader on the subscriptions you want scanned, and on the "+
				"management group if --management-group was used — see README.md, 'Permissions'.\n",
			condense(err))
		return 1
	}

	// A subscription Azure does not report as Enabled cannot be read, and saying
	// so up front is more useful than six identical AuthorizationFailed errors.
	var scannable, disabled []subscription
	for _, s := range subscriptions {
		if state, ok := s.State.(string); !ok || state == "" || state == "Enabled" {
			scannable = append(scannable, s)
		} else {
			disabled = append(disabled, s)
		}
	}

	logf("\nSubscriptions to scan: %d", len(scannable))
	if len(disabled) > 0 {
		logf("Subscriptions not enabled, recorded as skipped: %d", len(disabled))
	}
	if len(unreachable) > 0 {
		logf("Subscriptions this identity cannot read, recorded as failed: %d", len(unreachable))
		for _, u := range unreachable {
			logf("  [gap] %s: %s", u.ID, u.Reason)
		}
		logf("  Grant Reader at the tenant root management group to cover them — see README.md, 'Permissions'.")
	}
	if !scope.Verified {
		// Loud, because it is the one thing that cannot be recovered from the
		// file afterwards: what is absent is absent without trace.
		logf("\n  [warn] %v", scope.Note)
	}

	outputFile := opt.output
	if outputFile == "" {
		outputFile = "discovery_azure_" + time.Now().Format("20060102_150405") + ".json"
	}

	// Checked up front — a scan that cannot write its results is worth failing
	// immediately, not after an hour of API calls. The message names the path.
	file, err := os.Create(outputFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: cannot write output file '%s' — %s. "+
			"Check the directory exists and is writable.\n", outputFile, errnoText(err))
		return 1
	}
	writer := bufio.NewWriter(file)

	tally := map[string]int{"ok": 0, "partial": 0, "failed": 0, "skipped": 0}
	emit := func(record map[string]any) {
		line, _ := json.Marshal(record)
		writer.Write(line)
		writer.WriteByte('\n')
		if status, ok := record["status"].(string); ok {
			tally[status]++
		}
	}

	for _, sub := range disabled {
		emit(subscriptionRecord(sub, "skipped",
			fmt.Sprintf("subscription state is %s, not 'Enabled'", quotePython(sub.State))))
	}

	// Subscriptions the hierarchy says exist but this identity cannot read.
	// Recorded rather than dropped: an unreachable subscription that leaves no
	// trace in the file is the one failure the customer cannot see.
	for _, u := range unreachable {
		emit(subscriptionRecord(subscription{ID: u.ID, TenantID: nilIfEmpty(opt.tenant)}, "failed", u.Reason))
	}

	// Records are written as each subscription completes, so an interrupted run
	// keeps everything already collected.
	recorded := map[string]bool{}
	var (
		mu   sync.Mutex
		wg   sync.WaitGroup
		gate = make(chan struct{}, maxSubscriptionWorkers)
		done int
	)

	for _, sub := range scannable {
		if ctx.Err() != nil {
			break
		}
		wg.Add(1)
		s := sub
		go func() {
			defer wg.Done()
			gate <- struct{}{}
			defer func() { <-gate }()
			if ctx.Err() != nil {
				return
			}
			record := scanSubscription(ctx, client, s)

			mu.Lock()
			defer mu.Unlock()
			emit(record)
			recorded[s.ID] = true
			done++
			logf("  [%d/%d] %s — %s, %d disks, %d VMs", done, len(scannable), s.ID,
				record["status"], len(record["disks"].([]any)), len(record["virtual_machines"].([]any)))
			for _, e := range record["errors"].([]any) {
				logf("         %s: %v", s.ID, e)
			}
		}()
	}
	wg.Wait()

	// Subscriptions that never produced a record are still named, so the gap is
	// visible in the file rather than only in the tallies.
	if *interrupted {
		for _, sub := range scannable {
			if !recorded[sub.ID] {
				emit(subscriptionRecord(sub, "failed", "run interrupted before this subscription finished"))
			}
		}
	}

	summary := map[string]any{
		"record_type":  "summary",
		"tool_version": version,
		"cloud":        "azure",
		"scanned_at":   nowUTC(),
		"interrupted":  *interrupted,
		// False when the run could not establish what the tenant contains, so
		// the totals below are "what was visible", not "what exists".
		"scope_verified":        scope.Verified,
		"scope_note":            scope.Note,
		"subscriptions_total":   len(subscriptions) + len(unreachable),
		"subscriptions_scanned": tally["ok"],
		"subscriptions_partial": tally["partial"],
		"subscriptions_failed":  tally["failed"],
		"subscriptions_skipped": tally["skipped"],
	}
	line, _ := json.Marshal(summary)
	writer.Write(line)
	writer.WriteByte('\n')
	writer.Flush()
	file.Close()

	if *interrupted {
		logf("\nRun was interrupted — the results below are partial.")
	}
	logf("\nSubscriptions: %d total, %d scanned, %d partial, %d failed, %d skipped",
		summary["subscriptions_total"], tally["ok"], tally["partial"], tally["failed"], tally["skipped"])
	logf("Output:   %s", outputFile)
	if tally["partial"]+tally["failed"]+tally["skipped"] > 0 {
		logf("\nSome subscriptions were not fully scanned. Every one is recorded in")
		logf("%s with a status and a reason — send the file as-is.", outputFile)
	}
	if !scope.Verified {
		logf("\nCoverage could not be verified: the totals above count only what this")
		logf("identity can see, which may be less than the tenant contains. The summary")
		logf("record carries scope_verified=false so the file says so too.")
	}

	// Conventional 128+signal, matching the other implementations, so a wrapper
	// can tell an interrupted run from a complete one.
	if *interrupted {
		return 128 + *interruptSignal
	}
	return 0
}

// quotePython renders a value the way Python's !r does, so the skip reason text
// is identical across the three implementations.
func quotePython(v any) string {
	if s, ok := v.(string); ok {
		return "'" + s + "'"
	}
	if v == nil {
		return "None"
	}
	return fmt.Sprintf("%v", v)
}

func nilIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func errnoText(err error) string {
	msg := err.Error()
	if i := strings.LastIndex(msg, ": "); i >= 0 {
		return msg[i+2:]
	}
	return msg
}
