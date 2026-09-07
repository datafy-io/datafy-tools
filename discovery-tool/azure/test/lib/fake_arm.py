#!/usr/bin/env python3
"""
A fake Azure Resource Manager, for the discovery tool's test suite.

Serves the handful of ARM routes the tool calls, shaped exactly as ARM shapes
them, from a scenario file named by FAKE_ARM_SCENARIO. Prints the port it bound
to on stdout, then serves until killed.

It speaks HTTPS with a certificate it generates at startup, because azure-core
refuses to attach a bearer token to a plain-http URL — as it should. The harness
points REQUESTS_CA_BUNDLE at that certificate, so the tool under test needs no
test-only switch: the real credential policy, the real retry policy and the real
pagination all run exactly as they would against Azure.

Scenario keys, all optional:

  tenant_id           tenant reported for every subscription
  subscriptions       [{"id","name","state","tenant_id"}] or ["sub-id", ...]
  disks/vms/snapshots/images/scale_sets/vaults/policies
                      how many of each to generate per subscription
  per_subscription    {"<sub-id>": {"disks": 5, ...}} — overrides the above
  locations           locations to spread generated resources across
  page_size           if set, list responses paginate at this many items
  deny                ["Microsoft.Compute/disks", ...] — answer 403
  deny_by_subscription  {"<sub-id>": ["Microsoft.Compute/disks"]}, "*" for all
  throttle            {"Microsoft.Compute/disks": 3} — 429 the first 3 calls
  corrupt             ["Microsoft.Compute/snapshots"] — answer 200 with non-JSON
  reject_status_only  true — deny the statusOnly=true pass, to exercise the
                      degradation where VMs are listed but run state is not
  invisible_subscriptions
                      ids omitted from /subscriptions the way ARM omits
                      subscriptions no role assignment reaches, while the
                      management group hierarchy still lists them
  deny_tenant_root    true — 403 the tenant root management group, so no
                      denominator can be established at all
  management_groups   {"mg-id": ["sub-id", ...]}. The tenant root group (named
                      by tenant_id) is served automatically from every
                      subscription unless overridden here.
  delay_ms            sleep this long before answering, to widen the race window
"""

import json
import os
import ssl
import threading
import time
import datetime
import ipaddress
import pathlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

SCENARIO = json.loads(pathlib.Path(os.environ["FAKE_ARM_SCENARIO"]).read_text())
CERT_DIR = pathlib.Path(os.environ.get("FAKE_ARM_CERT_DIR") or ".")

DEFAULT_LOCATIONS = SCENARIO.get("locations") or ["westeurope", "eastus"]
TENANT = SCENARIO.get("tenant_id") or "11111111-1111-1111-1111-111111111111"


# ── Certificate ────────────────────────────────────────────────────────────────

def write_cert(directory):
    from cryptography import x509
    from cryptography.x509.oid import NameOID
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    directory.mkdir(parents=True, exist_ok=True)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])

    # Short-lived and fully specified, because Go on macOS applies Apple's
    # certificate policy: a lifetime over 825 days, or a missing extended key
    # usage, is rejected outright as "not standards compliant". Python's
    # requests would have accepted a sloppier certificate, so getting this
    # right is what lets one fake serve all three implementations.
    now = datetime.datetime.now(datetime.timezone.utc)
    start = now - datetime.timedelta(days=1)
    end = now + datetime.timedelta(days=365)

    cert = (
        x509.CertificateBuilder()
        .subject_name(name).issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(start).not_valid_after(end)
        .add_extension(x509.SubjectAlternativeName([
            x509.DNSName("localhost"),
            x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
        ]), critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(x509.KeyUsage(
            digital_signature=True, key_encipherment=True, key_cert_sign=True,
            content_commitment=False, data_encipherment=False, key_agreement=False,
            crl_sign=False, encipher_only=False, decipher_only=False,
        ), critical=True)
        .add_extension(x509.ExtendedKeyUsage([
            x509.oid.ExtendedKeyUsageOID.SERVER_AUTH,
        ]), critical=False)
        .sign(key, hashes.SHA256())
    )
    (directory / "key.pem").write_bytes(key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption()))
    (directory / "cert.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    return directory / "cert.pem", directory / "key.pem"


# ── Scenario helpers ───────────────────────────────────────────────────────────

def all_subscriptions():
    """Every subscription the scenario describes, visible or not."""
    return SCENARIO.get("subscriptions") or ["00000000-0000-0000-0000-000000000001"]


def invisible():
    """Subscriptions no role assignment reaches, right now.

    Real ARM does not return these from /subscriptions at all — it does not list
    them as denied, it omits them. Modelling that is the whole point: a tool
    that trusts /subscriptions as its denominator cannot tell a fully-granted
    tenant from a half-granted one, and its output looks identical either way.

    A grant at a management group scope makes its members visible from then on,
    which is what --setup-role is for. Without that, a test could not tell the
    flag working from the flag doing nothing.
    """
    hidden = set(SCENARIO.get("invisible_subscriptions") or [])
    if not hidden:
        return hidden
    with _lock:
        scopes = set(GRANTED_SCOPES)
    for scope in scopes:
        group = scope.rstrip("/").rsplit("/", 1)[-1]
        hidden -= _group_members(group)
    if SCENARIO.get("propagation_polls"):
        # Model RBAC propagation lag: the grant is written, but the new access
        # is not usable for the first few polls. A tool that scans the instant
        # the PUT returns would miss exactly the subscriptions it just granted
        # itself — and would look like the flag had failed, right after it
        # worked.
        with _lock:
            PROPAGATION["polls"] += 1
            if PROPAGATION["polls"] <= SCENARIO["propagation_polls"]:
                return set(SCENARIO.get("invisible_subscriptions") or [])
    return hidden


def _group_members(group):
    configured = SCENARIO.get("management_groups") or {}
    if group in configured:
        return set(configured[group])
    if group == TENANT:
        return {e if isinstance(e, str) else e["id"] for e in all_subscriptions()}
    return set()


def subscriptions():
    raw = [e for e in all_subscriptions()
           if (e if isinstance(e, str) else e["id"]) not in invisible()]
    out = []
    for entry in raw:
        if isinstance(entry, str):
            entry = {"id": entry}
        out.append({
            "subscriptionId": entry["id"],
            "displayName":    entry.get("name") or f"sub {entry['id']}",
            "state":          entry.get("state") or "Enabled",
            "tenantId":       entry.get("tenant_id") or TENANT,
            "id":             f"/subscriptions/{entry['id']}",
        })
    return out


def count_for(sub_id, key, default=0):
    per = (SCENARIO.get("per_subscription") or {}).get(sub_id) or {}
    if key in per:
        return per[key]
    return SCENARIO.get(key, default)


def denied(sub_id, resource_type):
    if resource_type in (SCENARIO.get("deny") or []):
        return True
    per = (SCENARIO.get("deny_by_subscription") or {}).get(sub_id) or []
    return "*" in per or resource_type in per


def location_for(index):
    return DEFAULT_LOCATIONS[index % len(DEFAULT_LOCATIONS)]


# ── Resource generation ────────────────────────────────────────────────────────
# Deterministic, so two runs of the same scenario produce byte-identical data.

def rid(sub, rg, provider, name):
    return f"/subscriptions/{sub}/resourceGroups/{rg}/providers/{provider}/{name}"


def make_disks(sub, n):
    out = []
    for i in range(n):
        attached = i % 3 != 0     # two of every three attached, one unattached
        out.append({
            "id": rid(sub, f"rg-{i % 4}", "Microsoft.Compute/disks", f"disk-{i}"),
            "name": f"disk-{i}",
            "type": "Microsoft.Compute/disks",
            "location": location_for(i),
            "zones": ["1"] if i % 2 else [],
            "tags": {"env": "test", "index": str(i)},
            "sku": {"name": "Premium_LRS", "tier": "Premium"},
            "managedBy": rid(sub, f"rg-{i % 4}", "Microsoft.Compute/virtualMachines",
                             f"vm-{i}") if attached else None,
            "properties": {
                "diskSizeGB": 32 + i,
                "diskState": "Attached" if attached else "Unattached",
                "provisioningState": "Succeeded",
                "diskIOPSReadWrite": 500,
                "diskMBpsReadWrite": 100,
                "tier": "P4",
                "burstingEnabled": False,
                "osType": "Linux" if i % 2 else None,
                "encryption": {"type": "EncryptionAtRestWithPlatformKey"},
                "creationData": {"createOption": "Empty"},
                "timeCreated": "2026-01-02T03:04:05.000Z",
            },
        })
    return out


def make_vms(sub, n, with_instance_view):
    out = []
    for i in range(n):
        props = {
            "vmId": f"vmid-{sub}-{i}",
            "hardwareProfile": {"vmSize": "Standard_D2s_v3"},
            "provisioningState": "Succeeded",
            "licenseType": "Windows_Server" if i % 4 == 0 else None,
            "storageProfile": {
                "osDisk": {
                    "name": f"vm-{i}-osdisk", "osType": "Linux", "diskSizeGB": 30,
                    "caching": "ReadWrite", "createOption": "FromImage",
                    "managedDisk": {
                        "id": rid(sub, f"rg-{i % 4}", "Microsoft.Compute/disks", f"vm-{i}-osdisk"),
                        "storageAccountType": "Premium_LRS",
                    },
                },
                "dataDisks": [{
                    "lun": 0, "name": f"vm-{i}-data0", "diskSizeGB": 128,
                    "caching": "None", "createOption": "Attach",
                    "managedDisk": {
                        "id": rid(sub, f"rg-{i % 4}", "Microsoft.Compute/disks", f"vm-{i}-data0"),
                        "storageAccountType": "StandardSSD_LRS",
                    },
                }] if i % 2 else [],
                "imageReference": {
                    "publisher": "Canonical", "offer": "0001-com-ubuntu-server-jammy",
                    "sku": "22_04-lts-gen2", "version": "latest",
                    "exactVersion": "22.04.202601010",
                },
            },
        }
        if with_instance_view:
            props["instanceView"] = {"statuses": [
                {"code": "ProvisioningState/succeeded", "displayStatus": "Provisioning succeeded"},
                {"code": "PowerState/running" if i % 3 else "PowerState/deallocated",
                 "displayStatus": "VM running"},
            ]}
        out.append({
            "id": rid(sub, f"rg-{i % 4}", "Microsoft.Compute/virtualMachines", f"vm-{i}"),
            "name": f"vm-{i}",
            "type": "Microsoft.Compute/virtualMachines",
            "location": location_for(i),
            "zones": [],
            "tags": {"env": "test"},
            "properties": props,
        })
    return out


def make_vm_statuses(sub, n):
    """What statusOnly=true returns: run-time status, not the whole VM.

    Deliberately reduced to the fields ARM documents for this pass, so a tool
    that quietly depended on the rest of the VM payload being here would fail
    the suite.
    """
    return [{
        "id": rid(sub, f"rg-{i % 4}", "Microsoft.Compute/virtualMachines", f"vm-{i}"),
        "name": f"vm-{i}",
        "type": "Microsoft.Compute/virtualMachines",
        "location": location_for(i),
        "properties": {"instanceView": {"statuses": [
            {"code": "ProvisioningState/succeeded", "displayStatus": "Provisioning succeeded"},
            {"code": "PowerState/running" if i % 3 else "PowerState/deallocated",
             "displayStatus": "VM running"},
        ]}},
    } for i in range(n)]


def make_snapshots(sub, n):
    return [{
        "id": rid(sub, f"rg-{i % 4}", "Microsoft.Compute/snapshots", f"snap-{i}"),
        "name": f"snap-{i}",
        "type": "Microsoft.Compute/snapshots",
        "location": location_for(i),
        "tags": {},
        "sku": {"name": "Standard_LRS", "tier": "Standard"},
        "properties": {
            "diskSizeGB": 32 + i,
            "diskState": "Unattached",
            "incremental": i % 2 == 0,
            "osType": "Linux",
            "encryption": {"type": "EncryptionAtRestWithPlatformKey"},
            "creationData": {
                "createOption": "Copy",
                "sourceResourceId": rid(sub, f"rg-{i % 4}", "Microsoft.Compute/disks", f"disk-{i}"),
            },
            "timeCreated": "2026-02-03T04:05:06.000Z",
        },
    } for i in range(n)]


def make_images(sub, n):
    return [{
        "id": rid(sub, f"rg-{i % 4}", "Microsoft.Compute/images", f"image-{i}"),
        "name": f"image-{i}",
        "type": "Microsoft.Compute/images",
        "location": location_for(i),
        "tags": {},
        "properties": {
            "provisioningState": "Succeeded",
            "hyperVGeneration": "V2",
            "sourceVirtualMachine": {
                "id": rid(sub, f"rg-{i % 4}", "Microsoft.Compute/virtualMachines", f"vm-{i}")},
            "storageProfile": {
                "osDisk": {"osType": "Linux", "osState": "Generalized", "diskSizeGB": 30},
                "dataDisks": [],
            },
        },
    } for i in range(n)]


def make_scale_sets(sub, n):
    return [{
        "id": rid(sub, f"rg-{i % 4}", "Microsoft.Compute/virtualMachineScaleSets", f"vmss-{i}"),
        "name": f"vmss-{i}",
        "type": "Microsoft.Compute/virtualMachineScaleSets",
        "location": location_for(i),
        "zones": ["1", "2"],
        "tags": {},
        "sku": {"name": "Standard_D2s_v3", "tier": "Standard", "capacity": 3 + i},
        "properties": {
            "orchestrationMode": "Uniform",
            "provisioningState": "Succeeded",
            "virtualMachineProfile": {"storageProfile": {
                "osDisk": {"osType": "Linux", "diskSizeGB": 30,
                           "managedDisk": {"storageAccountType": "Premium_LRS"}},
                "dataDisks": [{"lun": 0, "diskSizeGB": 64, "caching": "None",
                               "managedDisk": {"storageAccountType": "Premium_LRS"}}],
            }},
        },
    } for i in range(n)]


def make_vaults(sub, n, provider):
    short = "vault" if provider.startswith("Microsoft.RecoveryServices") else "bvault"
    return [{
        "id": rid(sub, f"rg-{i % 4}", provider, f"{short}-{i}"),
        "name": f"{short}-{i}",
        "type": provider,
        "location": location_for(i),
        "tags": {},
        "sku": {"name": "RS0"},
        "properties": {"provisioningState": "Succeeded"},
    } for i in range(n)]


def make_policies(sub, rg, provider, vault, n):
    return [{
        "id": rid(sub, rg, provider, f"{vault}/backupPolicies/policy-{i}"),
        "name": f"policy-{i}",
        "type": f"{provider}/backupPolicies",
        "properties": {
            "backupManagementType": "AzureIaasVM",
            "policyType": "V2",
            "protectedItemsCount": i,
            "datasourceTypes": ["Microsoft.Compute/disks"],
        },
    } for i in range(n)]


# ── Server ─────────────────────────────────────────────────────────────────────

STATS = {"calls": 0, "peak_concurrent": 0, "throttled": 0, "pages": 0}
BY_TYPE = {}
# Role assignments this run created, by assignment name, and the scopes they
# grant. A test asserts on both: that the scan was preceded by a grant, and that
# the grant was gone by the end.
ASSIGNMENTS = {}
GRANTED_SCOPES = set()
PROPAGATION = {"polls": 0}
_inflight = 0
_lock = threading.Lock()
_throttle_seen = {}


def note_call(resource_type):
    """Count a call against its resource type.

    Separate from the in-flight bookkeeping, which is done around the whole
    request in do_GET: a scenario delay is applied before routing, so counting
    concurrency from here would measure only the JSON generation and report a
    parallel scan as a serial one.
    """
    with _lock:
        STATS["calls"] += 1
        BY_TYPE[resource_type] = BY_TYPE.get(resource_type, 0) + 1


def end_call():
    pass


def should_throttle(resource_type):
    budget = (SCENARIO.get("throttle") or {}).get(resource_type)
    if not budget:
        return False
    with _lock:
        seen = _throttle_seen.get(resource_type, 0)
        if seen >= budget:
            return False
        _throttle_seen[resource_type] = seen + 1
        STATS["throttled"] += 1
        return True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    # -- replies ---------------------------------------------------------------

    def _send(self, status, body, content_type="application/json"):
        payload = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        if status == 429:
            self.send_header("Retry-After", "1")
        self.end_headers()
        self.wfile.write(payload)

    def _error(self, status, code, message):
        self._send(status, {"error": {"code": code, "message": message}})

    def _paged(self, items):
        """A list response, paginated the way ARM paginates: an absolute
        nextLink carrying its own continuation token."""
        size = SCENARIO.get("page_size")
        query = parse_qs(urlparse(self.path).query)
        skip = int((query.get("__skip") or ["0"])[0])
        with _lock:
            STATS["pages"] += 1
        if not size:
            return self._send(200, {"value": items})
        page = items[skip:skip + size]
        body = {"value": page}
        if skip + size < len(items):
            base = urlparse(self.path).path
            host = f"https://127.0.0.1:{self.server.server_address[1]}"
            api = (query.get("api-version") or ["2023-04-02"])[0]
            body["nextLink"] = f"{host}{base}?api-version={api}&__skip={skip + size}"
        self._send(200, body)

    # -- routing ---------------------------------------------------------------

    def do_GET(self):
        """Wraps the routing so peak concurrency covers the whole request,
        scenario delay included — which is what makes it a measure of how
        parallel the tool actually is."""
        global _inflight
        with _lock:
            _inflight += 1
            STATS["peak_concurrent"] = max(STATS["peak_concurrent"], _inflight)
        try:
            self._route()
        finally:
            with _lock:
                _inflight -= 1

    # -- role assignments (--setup-role) ---------------------------------------

    def do_PUT(self):
        """Create a role assignment.

        Grants are recorded, and a granted management group scope makes its
        subscriptions visible to /subscriptions from then on — which is the
        whole behaviour --setup-role exists to produce, and the only way a test
        can tell it apart from the flag quietly doing nothing.
        """
        # Drain the request body before answering. These are keep-alive
        # connections, so a body left unread stays in the socket buffer and gets
        # parsed as the head of the *next* request on it — which shows up as an
        # unrelated 400 on whatever call happens to follow.
        self.rfile.read(int(self.headers.get("Content-Length") or 0))

        path = urlparse(self.path).path
        parts = [p for p in path.strip("/").split("/") if p]
        if parts[-2:-1] != ["roleAssignments"]:
            return self._error(404, "NotFound", f"no route for PUT {path}")

        note_call("roleAssignments/write")
        if SCENARIO.get("deny_role_write"):
            return self._error(403, "AuthorizationFailed",
                               "The client does not have authorization to perform action "
                               "'Microsoft.Authorization/roleAssignments/write' over scope "
                               f"{'/'.join(parts[:-2])}.")

        name = parts[-1]
        # Strip the four trailing segments the assignment id adds —
        # providers/Microsoft.Authorization/roleAssignments/<name> — to get back
        # to the scope it was made at.
        scope = "/" + "/".join(parts[:-4])

        if SCENARIO.get("role_already_exists"):
            # A standing assignment. ARM refuses to create a duplicate, and the
            # access it grants is already in effect — so the scope counts as
            # granted, but nothing here is ours to remove afterwards.
            with _lock:
                GRANTED_SCOPES.add(scope)
            return self._error(409, "RoleAssignmentExists",
                               "The role assignment already exists.")

        with _lock:
            ASSIGNMENTS[name] = scope
            GRANTED_SCOPES.add(scope)
        self._send(201, {"id": path, "name": name,
                         "properties": {"scope": scope}})

    def do_DELETE(self):
        path = urlparse(self.path).path
        parts = [p for p in path.strip("/").split("/") if p]
        if parts[-2:-1] != ["roleAssignments"]:
            return self._error(404, "NotFound", f"no route for DELETE {path}")

        note_call("roleAssignments/delete")
        name = parts[-1]
        with _lock:
            scope = ASSIGNMENTS.pop(name, None)
            GRANTED_SCOPES.discard(scope)
        if scope is None:
            # ARM answers 204 when there was nothing to remove.
            self.send_response(204)
            self.send_header("Content-Length", "0")
            return self.end_headers()
        self._send(200, {"id": path, "name": name})

    def _route(self):
        path = urlparse(self.path).path
        query = parse_qs(urlparse(self.path).query)

        if path == "/__stats":
            with _lock:
                return self._send(200, {**STATS, "by_type": dict(BY_TYPE),
                                        "granted_scopes": sorted(GRANTED_SCOPES),
                                        "assignments": len(ASSIGNMENTS)})

        if SCENARIO.get("delay_ms"):
            time.sleep(SCENARIO["delay_ms"] / 1000.0)

        parts = [p for p in path.strip("/").split("/") if p]

        if parts == ["subscriptions"]:
            note_call("subscriptions")
            try:
                return self._paged(subscriptions())
            finally:
                end_call()

        if parts[:3] == ["providers", "Microsoft.Management", "managementGroups"] \
                and parts[-1] == "descendants":
            note_call("descendants")
            try:
                group = parts[3]
                configured = SCENARIO.get("management_groups") or {}
                if group in configured:
                    members = configured[group]
                elif group == TENANT and not SCENARIO.get("deny_tenant_root"):
                    # The tenant root group lists membership, not access, so it
                    # sees the invisible subscriptions too.
                    members = [e if isinstance(e, str) else e["id"]
                               for e in all_subscriptions()]
                elif group == TENANT:
                    return self._error(403, "AuthorizationFailed",
                                       "The client does not have authorization to perform action "
                                       "'Microsoft.Management/managementGroups/read' over scope "
                                       f"/providers/Microsoft.Management/managementGroups/{group}.")
                else:
                    return self._error(404, "NotFound", f"management group {group} not found")
                return self._paged([{
                    "id": f"/providers/Microsoft.Management/managementGroups/{group}/subscriptions/{m}",
                    "type": "Microsoft.Management/managementGroups/subscriptions",
                    "name": m,
                } for m in members])
            finally:
                end_call()

        if parts[0] == "subscriptions" and len(parts) >= 2:
            return self._subscription_scoped(parts, query)

        return self._error(404, "NotFound", f"no route for {path}")

    def _subscription_scoped(self, parts, query):
        sub = parts[1]
        known = {s["subscriptionId"] for s in subscriptions()}
        if sub not in known:
            return self._error(404, "SubscriptionNotFound", f"subscription {sub} not found")

        # /subscriptions/<sub>/resourceGroups/<rg>/providers/<ns>/<type>/<name>/backupPolicies
        if len(parts) >= 9 and parts[2].lower() == "resourcegroups" and parts[-1] == "backupPolicies":
            provider = f"{parts[5]}/{parts[6]}"
            vault    = parts[7]
            resource_type = f"{provider}/backupPolicies"
            note_call(resource_type)
            try:
                if denied(sub, resource_type) or denied(sub, provider):
                    return self._error(403, "AuthorizationFailed",
                                       f"The client does not have authorization to perform "
                                       f"action 'read' over scope {'/'.join(parts)}.")
                n = count_for(sub, "policies", 0)
                return self._paged(make_policies(sub, parts[3], provider, vault, n))
            finally:
                end_call()

        # /subscriptions/<sub>/providers/<ns>/<type>
        if len(parts) == 5 and parts[2] == "providers":
            resource_type = f"{parts[3]}/{parts[4]}"
            note_call(resource_type)
            try:
                return self._provider_list(sub, resource_type, query)
            finally:
                end_call()

        return self._error(404, "NotFound", f"no route for /{'/'.join(parts)}")

    def _provider_list(self, sub, resource_type, query):
        if should_throttle(resource_type):
            return self._error(429, "TooManyRequests",
                               "Rate limit exceeded for this subscription.")

        if denied(sub, resource_type):
            return self._error(403, "AuthorizationFailed",
                               f"The client does not have authorization to perform action "
                               f"'{resource_type}/read' over scope /subscriptions/{sub}.")

        if resource_type in (SCENARIO.get("corrupt") or []):
            return self._send(200, b"<html>not json at all</html>", "application/json")

        # Real ARM refuses to expand the instance view at subscription scope —
        # verbatim, this is what it answers. Modelled unconditionally rather
        # than behind a scenario flag, because it is not a scenario: it is how
        # ARM behaves, and the first version of this fake got it wrong, so the
        # suite passed while a real tenant returned 400.
        if resource_type == "Microsoft.Compute/virtualMachines" and \
                any("instanceView" in v for k, vs in query.items()
                    if k.startswith("$expand") for v in vs):
            return self._error(
                400, "BadRequest",
                "Expand Instance View is only supported when Virtual Machine "
                "Scale Set resource filter is applied")

        # statusOnly=true is the supported way to get run-time status for every
        # VM in a subscription.
        status_only = any(v.lower() == "true" for v in (query.get("statusOnly") or []))
        if status_only and SCENARIO.get("reject_status_only"):
            return self._error(403, "AuthorizationFailed",
                               "The client does not have authorization to perform action "
                               f"'{resource_type}/read' over scope /subscriptions/{sub}.")

        builders = {
            "Microsoft.Compute/disks":
                lambda: make_disks(sub, count_for(sub, "disks")),
            "Microsoft.Compute/virtualMachines":
                lambda: (make_vm_statuses(sub, count_for(sub, "vms")) if status_only
                         else make_vms(sub, count_for(sub, "vms"), False)),
            "Microsoft.Compute/snapshots":
                lambda: make_snapshots(sub, count_for(sub, "snapshots")),
            "Microsoft.Compute/images":
                lambda: make_images(sub, count_for(sub, "images")),
            "Microsoft.Compute/virtualMachineScaleSets":
                lambda: make_scale_sets(sub, count_for(sub, "scale_sets")),
            "Microsoft.RecoveryServices/vaults":
                lambda: make_vaults(sub, count_for(sub, "vaults"), "Microsoft.RecoveryServices/vaults"),
            "Microsoft.DataProtection/backupVaults":
                lambda: make_vaults(sub, count_for(sub, "backup_vaults", count_for(sub, "vaults")),
                                    "Microsoft.DataProtection/backupVaults"),
        }
        builder = builders.get(resource_type)
        if builder is None:
            return self._error(404, "NoRegisteredProviderFound",
                               f"No registered resource provider found for {resource_type}")
        return self._paged(builder())


def main():
    cert, key = write_cert(CERT_DIR)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(cert), str(key))
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
