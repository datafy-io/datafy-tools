package main

import (
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

// ── Subscription list ────────────────────────────────────────────────────────

type unreachableSub struct {
	ID     string
	Reason string
}

type scopeInfo struct {
	Verified bool
	Note     any
}

func normalizeSubscription(s map[string]any) subscription {
	id, _ := s["subscriptionId"].(string)
	return subscription{
		ID:          id,
		DisplayName: s["displayName"],
		State:       s["state"],
		TenantID:    s["tenantId"],
	}
}

// managementGroupSubscriptions returns subscription ids anywhere beneath a
// management group.
//
// /descendants walks the whole subtree, so a nested management group's
// subscriptions are included — which is what an operator naming their top-level
// "Production" group means. The response mixes child management groups in with
// subscriptions, hence the type filter.
func managementGroupSubscriptions(ctx context.Context, client *armClient, groupID string) (map[string]bool, error) {
	items, err := client.list(ctx,
		"/providers/Microsoft.Management/managementGroups/"+groupID+"/descendants",
		api["descendants"], nil)
	if err != nil {
		return nil, err
	}
	out := map[string]bool{}
	for _, raw := range items {
		item := asObject(raw)
		itemType, _ := item["type"].(string)
		name, _ := item["name"].(string)
		if name != "" && strings.HasSuffix(strings.ToLower(itemType), "/subscriptions") {
			out[name] = true
		}
	}
	return out, nil
}

// tenantRoots returns the tenant ids whose hierarchy is worth asking about.
//
// hint — the tenant from the access token — covers the case that matters most
// and is easiest to miss: an identity that can see no subscriptions at all has
// no tenant to derive from them, which is exactly when knowing what it is
// missing is worth the most.
func tenantRoots(subs []subscription, tenant, hint string) []string {
	if tenant != "" {
		return []string{tenant}
	}
	seen := map[string]bool{}
	roots := []string{}
	for _, s := range subs {
		if t, ok := s.TenantID.(string); ok && t != "" && !seen[t] {
			seen[t] = true
			roots = append(roots, t)
		}
	}
	sort.Strings(roots)
	if len(roots) == 0 && hint != "" {
		return []string{hint}
	}
	return roots
}

// listSubscriptions returns what to scan, what is known to be missing, and
// whether that is knowable.
//
// The hard part in Azure is the denominator. GET /subscriptions returns only the
// subscriptions the identity can already see — a subscription no role
// assignment reaches is not listed as denied, it is simply absent.
// So this call cannot on its own tell a complete scan from a half-granted one:
// left alone it would report a tenant of two hundred as three subscriptions,
// indistinguishable from a healthy three-subscription tenant.
//
// The management group hierarchy is the denominator, because it lists
// subscriptions by membership rather than by access.
func listSubscriptions(ctx context.Context, client *armClient, tenant, managementGroup string,
	include []string, exclude map[string]bool, tenantHint string) ([]subscription, []unreachableSub, scopeInfo, error) {

	var subs []subscription
	raw, err := client.list(ctx, "/subscriptions", api["subscriptions"], nil)
	if err != nil {
		if len(include) == 0 {
			return nil, nil, scopeInfo{}, err
		}
		logf("  [warn] could not list subscriptions (%s); scanning the --include ids without their names", condense(err))
		for _, id := range include {
			subs = append(subs, subscription{ID: id})
		}
	} else {
		for _, item := range raw {
			subs = append(subs, normalizeSubscription(asObject(item)))
		}
	}

	if tenant != "" {
		kept := subs[:0]
		for _, s := range subs {
			if t, ok := s.TenantID.(string); !ok || t == "" || t == tenant {
				kept = append(kept, s)
			}
		}
		subs = kept
	}

	visible := map[string]bool{}
	for _, s := range subs {
		visible[s.ID] = true
	}

	var unreachable []unreachableSub
	scope := scopeInfo{Verified: false, Note: nil}

	switch {
	case managementGroup != "":
		// The group is the scope, so it is also the denominator.
		inGroup, mgErr := managementGroupSubscriptions(ctx, client, managementGroup)
		if mgErr != nil {
			return nil, nil, scopeInfo{}, mgErr
		}
		kept := subs[:0]
		for _, s := range subs {
			if inGroup[s.ID] {
				kept = append(kept, s)
			}
		}
		subs = kept
		for _, id := range sortedKeys(inGroup) {
			if !visible[id] {
				unreachable = append(unreachable, unreachableSub{id,
					"in management group " + managementGroup + ", but not visible to this identity — no role assignment reaches it"})
			}
		}
		scope = scopeInfo{true, "scope checked against management group " + managementGroup}

	case len(include) > 0:
		// An explicit list is its own denominator: the operator said what they
		// expected, so anything they named and we cannot see is a gap.
		scope = scopeInfo{true, "scope checked against --include"}

	default:
		expected := map[string]bool{}
		var failures []string
		checked := 0
		for _, root := range tenantRoots(subs, tenant, tenantHint) {
			found, rootErr := managementGroupSubscriptions(ctx, client, root)
			if rootErr != nil {
				failures = append(failures, "tenant "+root+": "+condense(rootErr))
				continue
			}
			for id := range found {
				expected[id] = true
			}
			checked++
		}
		for _, id := range sortedKeys(expected) {
			if !visible[id] {
				unreachable = append(unreachable, unreachableSub{id,
					"in the tenant hierarchy, but not visible to this identity — no role assignment reaches it"})
			}
		}
		if checked > 0 && len(failures) == 0 {
			scope = scopeInfo{true, "scope checked against the tenant root management group"}
		} else {
			detail := strings.Join(failures, "; ")
			if detail == "" {
				detail = "no tenant could be determined from the subscription list"
			}
			scope = scopeInfo{false, "scope NOT checked against the tenant root management group (" + detail +
				"). Subscriptions this identity cannot see are absent from this file and are not counted below — " +
				"do not read these totals as full tenant coverage."}
		}
	}

	if len(include) > 0 {
		wanted := map[string]bool{}
		for _, id := range include {
			wanted[id] = true
		}
		kept := subs[:0]
		for _, s := range subs {
			if wanted[s.ID] {
				kept = append(kept, s)
			}
		}
		subs = kept

		already := map[string]bool{}
		for _, u := range unreachable {
			already[u.ID] = true
		}
		// Named and not visible. Recorded, not merely warned about: a warning on
		// stderr is gone the moment the operator redirects it, and the file is
		// the only thing that gets sent to us.
		for _, id := range sortedKeys(wanted) {
			if !visible[id] && !already[id] {
				unreachable = append(unreachable, unreachableSub{id,
					"named by --include, but not visible to this identity — no role assignment reaches it"})
			}
		}
	}

	kept := subs[:0]
	for _, s := range subs {
		if !exclude[s.ID] {
			kept = append(kept, s)
		}
	}
	subs = kept

	keptUnreachable := unreachable[:0]
	for _, u := range unreachable {
		if !exclude[u.ID] {
			keptUnreachable = append(keptUnreachable, u)
		}
	}
	unreachable = keptUnreachable

	sort.Slice(subs, func(i, j int) bool { return subs[i].ID < subs[j].ID })
	sort.Slice(unreachable, func(i, j int) bool { return unreachable[i].ID < unreachable[j].ID })
	return subs, unreachable, scope, nil
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// ── Reader access setup (--setup-role) ───────────────────────────────────────
// Grant the access the scan needs, scan, then always take it away again —
// including when the scan fails.
//
// Because Azure RBAC inherits, this is one PUT and one DELETE however large the
// tenant: a single assignment at a tenant root management group covers every
// subscription beneath it, present and future.

// tokenClaims returns the claims inside a JWT, without verifying it.
//
// Only ever used to read our own access token's oid and tid. The token was just
// handed to us by our own credential and is about to be sent back to the issuer,
// which does verify it; nothing here is a trust decision.
func tokenClaims(token string) (map[string]any, error) {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return nil, fmt.Errorf("could not read the access token's claims: not a JWT")
	}
	payload := parts[1]
	if pad := len(payload) % 4; pad != 0 {
		payload += strings.Repeat("=", 4-pad)
	}
	data, err := base64.URLEncoding.DecodeString(payload)
	if err != nil {
		return nil, fmt.Errorf("could not read the access token's claims: %s", err)
	}
	var claims map[string]any
	if err := json.Unmarshal(data, &claims); err != nil {
		return nil, fmt.Errorf("could not read the access token's claims: %s", err)
	}
	return claims, nil
}

// tokenIdentity returns the principal object id and tenant id this tool runs as.
//
// Both are read from the access token rather than from Microsoft Graph, which
// would mean another dependency, another consent prompt and another permission
// to document — for two values the token already carries.
//
// The tenant has to come from here rather than from the subscription list,
// which is the trap: an identity with no role assignments anywhere sees an empty
// /subscriptions, so deriving the tenant from it fails in exactly the situation
// --setup-role exists to fix.
func tokenIdentity(ctx context.Context, client *armClient) (string, string, error) {
	token, err := client.bearer(ctx)
	if err != nil {
		return "", "", err
	}
	claims, err := tokenClaims(token)
	if err != nil {
		return "", "", err
	}
	oid, _ := claims["oid"].(string)
	if oid == "" {
		return "", "", fmt.Errorf("the access token carries no 'oid' claim, so the identity to grant " +
			"Reader to cannot be determined. Sign in as a user or service principal, or grant Reader " +
			"yourself and run without --setup-role")
	}
	tid, _ := claims["tid"].(string)
	return oid, tid, nil
}

// assignmentName derives a deterministic UUIDv5 for a (scope, principal) pair,
// so re-running --setup-role after a crash lands on the assignment the previous
// run left behind instead of stacking up a second one.
func assignmentName(scope, principal string) string {
	ns := strings.ReplaceAll(assignmentNSUUID, "-", "")
	nsBytes := make([]byte, 16)
	for i := 0; i < 16; i++ {
		fmt.Sscanf(ns[i*2:i*2+2], "%02x", &nsBytes[i])
	}
	h := sha1.New()
	h.Write(nsBytes)
	h.Write([]byte(scope + "|" + principal))
	sum := h.Sum(nil)
	sum[6] = (sum[6] & 0x0f) | 0x50 // version 5
	sum[8] = (sum[8] & 0x3f) | 0x80 // RFC 4122 variant
	return fmt.Sprintf("%x-%x-%x-%x-%x", sum[0:4], sum[4:6], sum[6:8], sum[8:10], sum[10:16])
}

func assignmentPath(scope, name string) string {
	return scope + "/providers/Microsoft.Authorization/roleAssignments/" + name
}

// grantReader assigns Reader to principal at scope.
//
// Returns true if this call created the assignment, false if an equivalent one
// was already there. The distinction is load-bearing: teardown removes only what
// this run created, so a standing grant that happens to match is never revoked
// out from under the customer.
func grantReader(ctx context.Context, client *armClient, scope, principal string) (bool, error) {
	name := assignmentName(scope, principal)
	body := map[string]any{"properties": map[string]any{
		"roleDefinitionId": "/providers/Microsoft.Authorization/roleDefinitions/" + readerRoleID,
		"principalId":      principal,
	}}
	_, err := client.put(ctx, assignmentPath(scope, name), api["role_assignments"], body)
	if err != nil {
		var ae *armError
		if asARMError(err, &ae) &&
			(ae.Code == "RoleAssignmentExists" || ae.Code == "RoleAssignmentUpdateNotPermitted") {
			logf("  Reader is already assigned at %s — leaving it alone.", scope)
			return false, nil
		}
		return false, err
	}
	return true, nil
}

func revokeReader(ctx context.Context, client *armClient, scope, principal string) error {
	return client.delete(ctx, assignmentPath(scope, assignmentName(scope, principal)), api["role_assignments"])
}

// waitForPropagation blocks until the new access is usable, or the timeout
// expires.
//
// Azure does not make a role assignment effective the moment it is written.
// Scanning straight away would miss precisely the subscriptions --setup-role was
// used to reach, and would report them unreachable — a failure that looks
// exactly like the flag not working, immediately after it did.
func waitForPropagation(ctx context.Context, client *armClient, expected map[string]bool) {
	if len(expected) == 0 {
		return
	}
	deadline := time.Now().Add(time.Duration(propagationWait * float64(time.Second)))
	for {
		visible := map[string]bool{}
		raw, err := client.list(ctx, "/subscriptions", api["subscriptions"], nil)
		if err != nil {
			logf("  [warn] could not re-check visible subscriptions: %s", condense(err))
		}
		for _, item := range raw {
			if id, ok := asObject(item)["subscriptionId"].(string); ok {
				visible[id] = true
			}
		}

		missing := 0
		for id := range expected {
			if !visible[id] {
				missing++
			}
		}
		if missing == 0 {
			logf("  Reader is in effect across %d subscription(s).", len(expected))
			return
		}
		if time.Now().After(deadline) {
			logf("  [warn] %d subscription(s) still not visible after %.0fs. Scanning anyway — "+
				"every one of them is recorded in the output with a reason.", missing, propagationWait)
			return
		}
		logf("  Waiting for the role assignment to take effect (%d/%d visible)...",
			len(expected)-missing, len(expected))
		select {
		case <-time.After(time.Duration(propagationPoll * float64(time.Second))):
		case <-ctx.Done():
			return
		}
	}
}

type grantedScope struct{ Scope, Principal string }

// setupReaderAccess grants Reader everywhere this run needs it.
//
// The scope is always a management group, never a subscription, and that is the
// point: assigning at a tenant root covers every subscription beneath it, so a
// subscription the identity could not previously see becomes readable without
// having to be enumerated first. It could not have been enumerated — a
// subscription no assignment reaches is absent from /subscriptions entirely.
func setupReaderAccess(ctx context.Context, client *armClient, tenant, managementGroup string) ([]grantedScope, error) {
	principal, tokenTenant, err := tokenIdentity(ctx, client)
	if err != nil {
		return nil, err
	}
	logf("Granting Reader to principal %s...", principal)

	var groups []string
	if managementGroup != "" {
		groups = []string{managementGroup}
	} else {
		// --tenant first if given, then the token's own tenant. Deliberately not
		// the subscription list: an identity with no assignments anywhere sees
		// nothing there, and that is the case this flag is for.
		for _, g := range []string{tenant, tokenTenant} {
			if g != "" {
				groups = []string{g}
				break
			}
		}
		if len(groups) == 0 {
			return nil, fmt.Errorf("no tenant could be determined to grant Reader in — the access token " +
				"carries no 'tid' claim. Pass --tenant, or --management-group, to name the scope explicitly")
		}
	}

	var granted []grantedScope
	expected := map[string]bool{}
	for _, group := range groups {
		scope := "/providers/Microsoft.Management/managementGroups/" + group
		created, grantErr := grantReader(ctx, client, scope, principal)
		if grantErr != nil {
			return granted, grantErr
		}
		if created {
			granted = append(granted, grantedScope{scope, principal})
			logf("  Reader assigned at %s", scope)
		}
		found, mgErr := managementGroupSubscriptions(ctx, client, group)
		if mgErr != nil {
			logf("  [warn] could not read the hierarchy under %s: %s", scope, condense(mgErr))
			continue
		}
		for id := range found {
			expected[id] = true
		}
	}

	if len(granted) > 0 {
		waitForPropagation(ctx, client, expected)
	}
	return granted, nil
}

// teardownReaderAccess removes every assignment this run created. Never fails
// the run: a failure to clean up has to be shouted about rather than returned,
// since returning it would replace the real error with this one.
func teardownReaderAccess(client *armClient, granted []grantedScope) {
	for _, g := range granted {
		// A fresh context: the scan's may already be cancelled by an interrupt,
		// and cleanup still has to happen.
		ctx, cancel := contextWithTimeout(60 * time.Second)
		err := revokeReader(ctx, client, g.Scope, g.Principal)
		cancel()
		if err != nil {
			logf("  [warn] could not remove the Reader assignment at %s: %s", g.Scope, condense(err))
			logf("  Remove it by hand: az role assignment delete --assignee %s --role Reader --scope %s",
				g.Principal, g.Scope)
			continue
		}
		logf("Reader assignment removed from %s", g.Scope)
	}
}

func contextWithTimeout(d time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), d)
}

func asARMError(err error, target **armError) bool {
	if ae, ok := err.(*armError); ok {
		*target = ae
		return true
	}
	return false
}
