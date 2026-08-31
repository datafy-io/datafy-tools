package main

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"sync"
)

// ── Per-subscription scan ────────────────────────────────────────────────────

type subscription struct {
	ID          string
	DisplayName any
	State       any
	TenantID    any
}

// subscriptionRecord is the skeleton every subscription record shares.
//
// A subscription that could not be read still gets a record, with a status and
// a reason, so a missing subscription is visible in the file the customer sends
// us rather than only in a log they redirected away.
func subscriptionRecord(sub subscription, status string, reason any) map[string]any {
	return map[string]any{
		"record_type":        "subscription",
		"subscription_id":    sub.ID,
		"subscription_name":  sub.DisplayName,
		"tenant_id":          sub.TenantID,
		"subscription_state": sub.State,
		"status":             status,
		"reason":             reason,
		"scanned_at":         nowUTC(),
		"errors":             []any{},
		"locations":          []any{},
		"disks":              []any{},
		"virtual_machines":   []any{},
		"scale_sets":         []any{},
		"snapshots":          []any{},
		"images":             []any{},
		"backup_vaults":      []any{},
		"backup_policies":    []any{},
	}
}

// collector accumulates the per-call outcomes of one subscription scan.
type collector struct {
	mu       sync.Mutex
	errors   []string
	calls    int
	failures int
}

// attempt runs one ARM call, recording its failure rather than propagating it.
//
// Each call is attempted independently so the record can distinguish a
// subscription that is genuinely empty from one whose reads were denied.
func (c *collector) attempt(api string, fn func() ([]any, error)) []any {
	c.mu.Lock()
	c.calls++
	c.mu.Unlock()

	items, err := fn()
	if err != nil {
		c.mu.Lock()
		c.failures++
		c.errors = append(c.errors, api+": "+condense(err))
		c.mu.Unlock()
		return nil
	}
	return items
}

func (c *collector) note(api string, err error) {
	c.mu.Lock()
	c.calls++
	c.failures++
	c.errors = append(c.errors, api+": "+condense(err))
	c.mu.Unlock()
}

// scanSubscription collects all discovery data for one subscription.
//
// ARM list calls are scoped to a subscription and return every region at once,
// so a denied read costs a whole subscription rather than one region. That is
// why the record is per subscription, and why each resource carries its own
// location.
func scanSubscription(ctx context.Context, client *armClient, sub subscription) map[string]any {
	base := "/subscriptions/" + sub.ID + "/providers"
	col := &collector{}

	simple := func(name, providerPath, apiKey string, shaper func(map[string]any) map[string]any) []any {
		raw := col.attempt(name, func() ([]any, error) {
			return client.list(ctx, base+"/"+providerPath, api[apiKey], nil)
		})
		out := []any{}
		for _, item := range raw {
			out = append(out, shaper(asObject(item)))
		}
		return out
	}

	// listVMs collects VMs with run-time power state merged in from a second
	// pass.
	//
	// power_state lives in the instance view, and ARM will not expand it inline
	// at subscription scope — $expand=instanceView there is rejected outright,
	// because the expand is only honoured for a scale-set-filtered query. The
	// supported route for a whole subscription is a separate pass with
	// statusOnly=true.
	//
	// So the inventory call goes out plain, and first: it is the one that must
	// not be lost. If the status pass then fails, every VM is still reported
	// with power_state null, and the subscription is marked partial.
	listVMs := func() []any {
		path := base + "/Microsoft.Compute/virtualMachines"
		raw := col.attempt("Microsoft.Compute/virtualMachines", func() ([]any, error) {
			return client.list(ctx, path, api["virtual_machines"], nil)
		})
		vms := []any{}
		for _, item := range raw {
			vms = append(vms, shapeVM(asObject(item)))
		}
		if len(vms) == 0 {
			return vms
		}

		statuses := col.attempt("Microsoft.Compute/virtualMachines?statusOnly=true", func() ([]any, error) {
			return client.list(ctx, path, api["virtual_machines"], map[string]string{"statusOnly": "true"})
		})
		// Resource ids are compared case-insensitively: ARM echoes back whatever
		// casing a resource was created with, and the two passes are not
		// guaranteed to agree on it.
		power := map[string]any{}
		for _, item := range statuses {
			s := asObject(item)
			if id, ok := s["id"].(string); ok {
				power[strings.ToLower(id)] = powerState(asObject(s["properties"]))
			}
		}
		for _, item := range vms {
			vm := item.(map[string]any)
			if id, ok := vm["id"].(string); ok {
				vm["power_state"] = power[strings.ToLower(id)]
			}
		}
		return vms
	}

	// listBackup collects vaults and their policies, from both of Azure's
	// backup families. Policies are vault-scoped in ARM — there is no
	// subscription-wide list — so this is one call per vault. A vault whose
	// policies are denied still appears in backup_vaults with the failure
	// recorded against the subscription.
	listBackup := func() ([]any, []any) {
		vaults := []any{}
		policies := []any{}

		families := []struct{ vaultType, providerPath, vaultsKey, policiesKey string }{
			{"RecoveryServices", "Microsoft.RecoveryServices/vaults", "rsv_vaults", "rsv_policies"},
			{"DataProtection", "Microsoft.DataProtection/backupVaults", "dp_vaults", "dp_policies"},
		}

		for _, family := range families {
			f := family
			found := col.attempt(f.providerPath, func() ([]any, error) {
				return client.list(ctx, base+"/"+f.providerPath, api[f.vaultsKey], nil)
			})
			for _, raw := range found {
				vault := asObject(raw)
				vaults = append(vaults, shapeVault(vault, f.vaultType))

				rg, _ := resourceGroupOf(vault["id"]).(string)
				name, _ := vault["name"].(string)
				if rg == "" || name == "" {
					continue
				}
				policyPath := fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/%s/%s/backupPolicies",
					sub.ID, rg, f.providerPath, name)
				foundPolicies := col.attempt(f.providerPath+"/"+name+"/backupPolicies", func() ([]any, error) {
					return client.list(ctx, policyPath, api[f.policiesKey], nil)
				})
				for _, p := range foundPolicies {
					policies = append(policies, shapePolicy(asObject(p), vault, f.vaultType))
				}
			}
		}
		return vaults, policies
	}

	// The resource lists are independent of one another, so they go out
	// together rather than one at a time. The outer pool already keeps 20
	// subscriptions in flight; this is what keeps a tenant of two very large
	// subscriptions from being scanned essentially serially.
	var (
		wg        sync.WaitGroup
		collected = map[string][]any{}
		mu        sync.Mutex
	)
	set := func(key string, value []any) {
		mu.Lock()
		collected[key] = value
		mu.Unlock()
	}

	tasks := []func(){
		func() { set("disks", simple("Microsoft.Compute/disks", "Microsoft.Compute/disks", "disks", shapeDisk)) },
		func() { set("virtual_machines", listVMs()) },
		func() {
			set("scale_sets", simple("Microsoft.Compute/virtualMachineScaleSets",
				"Microsoft.Compute/virtualMachineScaleSets", "scale_sets", shapeScaleSet))
		},
		func() {
			set("snapshots", simple("Microsoft.Compute/snapshots", "Microsoft.Compute/snapshots", "snapshots", shapeSnapshot))
		},
		func() {
			set("images", simple("Microsoft.Compute/images", "Microsoft.Compute/images", "images", shapeImage))
		},
		func() {
			vaults, policies := listBackup()
			set("backup_vaults", vaults)
			set("backup_policies", policies)
		},
	}

	gate := make(chan struct{}, maxCallWorkers)
	for _, task := range tasks {
		wg.Add(1)
		t := task
		go func() {
			defer wg.Done()
			gate <- struct{}{}
			defer func() { <-gate }()
			t()
		}()
	}
	wg.Wait()

	status := "ok"
	if col.failures > 0 {
		if col.failures >= col.calls {
			status = "failed"
		} else {
			status = "partial"
		}
	}

	record := subscriptionRecord(sub, status, nil)
	keys := []string{"disks", "virtual_machines", "scale_sets", "snapshots", "images", "backup_vaults", "backup_policies"}
	for _, key := range keys {
		if v, ok := collected[key]; ok && v != nil {
			record[key] = v
		}
	}

	// Every location the subscription actually has something in. A scoping
	// conversation starts with "which regions are you in", and answering it from
	// the file should not mean unioning six arrays by hand.
	seen := map[string]bool{}
	for _, key := range []string{"disks", "virtual_machines", "scale_sets", "snapshots", "images", "backup_vaults"} {
		for _, item := range record[key].([]any) {
			if loc, ok := asObject(item)["location"].(string); ok && loc != "" {
				seen[loc] = true
			}
		}
	}
	locations := []any{}
	for loc := range seen {
		locations = append(locations, loc)
	}
	sort.Slice(locations, func(i, j int) bool { return locations[i].(string) < locations[j].(string) })
	record["locations"] = locations

	record["errors"] = uniqueSorted(col.errors)
	return record
}

func uniqueSorted(items []string) []any {
	seen := map[string]bool{}
	out := []string{}
	for _, item := range items {
		if !seen[item] {
			seen[item] = true
			out = append(out, item)
		}
	}
	sort.Strings(out)
	result := []any{}
	for _, item := range out {
		result = append(result, item)
	}
	return result
}
