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
  reject_expand       true — 400 any request carrying $expand
  management_groups   {"mg-id": ["sub-id", ...]}
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
    start = datetime.datetime(2020, 1, 1, tzinfo=datetime.timezone.utc)
    end   = datetime.datetime(2040, 1, 1, tzinfo=datetime.timezone.utc)
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
        .sign(key, hashes.SHA256())
    )
    (directory / "key.pem").write_bytes(key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption()))
    (directory / "cert.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    return directory / "cert.pem", directory / "key.pem"


# ── Scenario helpers ───────────────────────────────────────────────────────────

def subscriptions():
    raw = SCENARIO.get("subscriptions") or ["00000000-0000-0000-0000-000000000001"]
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

    def _route(self):
        path = urlparse(self.path).path
        query = parse_qs(urlparse(self.path).query)

        if path == "/__stats":
            with _lock:
                return self._send(200, {**STATS, "by_type": dict(BY_TYPE)})

        if SCENARIO.get("delay_ms"):
            time.sleep(SCENARIO["delay_ms"] / 1000.0)

        if SCENARIO.get("reject_expand") and any(k.startswith("$expand") for k in query):
            return self._error(400, "InvalidParameter",
                               "The parameter $expand is not supported at this scope.")

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
                members = (SCENARIO.get("management_groups") or {}).get(group)
                if members is None:
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

        want_instance_view = any("instanceView" in v for vs in query.values() for v in vs)

        builders = {
            "Microsoft.Compute/disks":
                lambda: make_disks(sub, count_for(sub, "disks")),
            "Microsoft.Compute/virtualMachines":
                lambda: make_vms(sub, count_for(sub, "vms"), want_instance_view),
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
