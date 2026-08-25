#!/usr/bin/env python3
"""
Datafy Discovery Tool — Azure
Inventories managed disks, virtual machines, snapshots, images and backup
policies across every subscription in an Azure tenant.
Read-only — safe to run in production.

Usage:
  # Scan every subscription the signed-in identity can see
  python3 discovery.py

  # Limit to one tenant
  python3 discovery.py --tenant 00000000-0000-0000-0000-000000000000

  # Limit to a management group
  python3 discovery.py --management-group mg-production

  # Specific subscriptions only
  python3 discovery.py --include 111...,222...

  # Skip specific subscriptions
  python3 discovery.py --exclude 333...

Unlike the AWS edition there is no role to assume: one identity holding Reader
at the tenant root management group reads every subscription directly. See
README.md for how to grant it.
"""

import argparse
import base64
import json
import os
import signal
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from urllib.parse import urlparse

try:
    from azure.core import PipelineClient
    from azure.core.credentials import AccessToken
    from azure.core.exceptions import ClientAuthenticationError
    from azure.core.pipeline.policies import (
        BearerTokenCredentialPolicy,
        ContentDecodePolicy,
        DistributedTracingPolicy,
        HeadersPolicy,
        HttpLoggingPolicy,
        ProxyPolicy,
        RedirectPolicy,
        RequestIdPolicy,
        RetryPolicy,
        SensitiveHeaderCleanupPolicy,
        UserAgentPolicy,
    )
    from azure.core.rest import HttpRequest
    from azure.identity import DefaultAzureCredential
except ImportError:                                  # pragma: no cover — install hint
    print(
        "Error: the Azure SDK is not installed.\n\n"
        "  pip install azure-identity\n\n"
        "That single package is all this tool needs — it pulls in azure-core, "
        "which carries the HTTP pipeline used here.",
        file=sys.stderr,
    )
    sys.exit(1)

# ── Configuration ──────────────────────────────────────────────────────────────
VERSION                 = "0.1.0"
USER_AGENT              = f"datafy-discovery-azure/{VERSION}"
MAX_SUBSCRIPTION_WORKERS = 20    # subscriptions scanned in parallel
MAX_CALL_WORKERS         = 8     # independent ARM calls in flight per subscription
MAX_ERROR_CHARS          = 400   # keep error strings readable in the output file
MAX_PAGES                = 10000 # nextLink guard — a loop must fail, not spin forever

# The ARM endpoint. Overridable for sovereign clouds (Azure Government, China)
# and for the test suite, which points it at a fake ARM.
ARM_ENDPOINT = (os.environ.get("AZURE_ARM_ENDPOINT") or "https://management.azure.com").rstrip("/")

# The scope a management-plane token is requested for. Follows the endpoint, so
# overriding one for a sovereign cloud does not silently leave the other on
# public-cloud values.
ARM_SCOPE = os.environ.get("AZURE_ARM_SCOPE") or f"{ARM_ENDPOINT}/.default"

# Retry policy. A tenant-wide scan makes thousands of ARM calls and Azure
# Resource Manager throttles per-subscription read quotas long before the end;
# a throttled call comes back 429 with a Retry-After header. Pinned rather than
# left to the client default so a run is reproducible, and so this edition rides
# out a burst the same way the AWS edition does — 10 total attempts, exponential
# backoff with jitter.
#
# AZURE_MAX_ATTEMPTS counts TOTAL attempts, the first one included, matching
# AWS_MAX_ATTEMPTS in the AWS edition. azure-core's own retry_total counts
# *retries*, so it is one lower — the same off-by-one botocore has between
# "max_attempts" and "total_max_attempts", and the reason neither is passed
# through raw.
MAX_ATTEMPTS    = max(1, int(os.environ.get("AZURE_MAX_ATTEMPTS") or 10))
RETRY_BACKOFF   = float(os.environ.get("AZURE_RETRY_BACKOFF") or 0.8)
RETRY_BACKOFF_MAX = float(os.environ.get("AZURE_RETRY_BACKOFF_MAX") or 120)

# ARM api-versions, pinned so the response shape is reproducible rather than
# whatever the provider happens to default to. Each is overridable from the
# environment: a subscription in a sovereign cloud or an early-access provider
# may not offer the version pinned here, and an operator needs to be able to
# move one without waiting for a release. A version a provider rejects is
# reported as an error against the subscription, never as an empty result.
def _api(name, default):
    return os.environ.get(f"AZURE_API_{name.upper()}") or default

API = {
    "subscriptions":     _api("subscriptions",     "2022-12-01"),
    "descendants":       _api("descendants",       "2021-04-01"),
    "disks":             _api("disks",             "2023-04-02"),
    "snapshots":         _api("snapshots",         "2023-04-02"),
    "virtual_machines":  _api("virtual_machines",  "2023-09-01"),
    "scale_sets":        _api("scale_sets",        "2023-09-01"),
    "images":            _api("images",            "2023-09-01"),
    "rsv_vaults":        _api("rsv_vaults",        "2023-04-01"),
    "rsv_policies":      _api("rsv_policies",      "2023-02-01"),
    "dp_vaults":         _api("dp_vaults",         "2023-05-01"),
    "dp_policies":       _api("dp_policies",       "2023-05-01"),
    "role_assignments":  _api("role_assignments",  "2022-04-01"),
}

# The built-in Reader role. This GUID is the same in every Azure cloud and
# tenant — built-in role definition ids are global constants.
READER_ROLE_ID = "acdd72a7-3385-48ef-bd42-f606fba81ae7"

# A fixed namespace, so the assignment name for a given principal and scope is
# always the same GUID. Re-running --setup-role after a crash then lands on the
# assignment the previous run left behind instead of stacking up a second one.
ASSIGNMENT_NAMESPACE = uuid.UUID("6f9d3a1e-0b6c-5f8a-9c2d-4e7b1a3f5c80")

# Role assignments are not effective the instant they are written; ARM has to
# propagate them. Scanning immediately would miss exactly the subscriptions
# --setup-role was used to reach, and would look like it had worked.
PROPAGATION_TIMEOUT = float(os.environ.get("AZURE_PROPAGATION_TIMEOUT") or 300)
PROPAGATION_POLL    = float(os.environ.get("AZURE_PROPAGATION_POLL") or 10)


# ── Utilities ──────────────────────────────────────────────────────────────────

def log(msg):
    """Progress and diagnostics, on stderr.

    The tool has one product — the JSONL file named by --output — and stdout is
    left clean for the caller. An operator who redirects stdout must still see
    that subscriptions were skipped. The AWS edition does the same.
    """
    print(msg, file=sys.stderr, flush=True)


def now_utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def condense(exc):
    """Squash an exception into one short line fit for a JSON field."""
    if isinstance(exc, ArmError):
        text = f"{exc.code}: {exc.message}"
    else:
        text = f"{type(exc).__name__}: {exc}"
    return " ".join(text.split())[:MAX_ERROR_CHARS]


def resource_group_of(resource_id):
    """The resource group name embedded in an ARM resource id, or None.

    Ids look like /subscriptions/<sub>/resourceGroups/<rg>/providers/...
    Matched case-insensitively: ARM echoes back whatever casing the caller used
    when the resource was created, so "resourcegroups" is as common as
    "resourceGroups" in real tenants.
    """
    if not resource_id:
        return None
    parts = resource_id.strip("/").split("/")
    for i, part in enumerate(parts):
        if part.lower() == "resourcegroups" and i + 1 < len(parts):
            return parts[i + 1]
    return None


def name_of(resource_id):
    """The trailing name segment of an ARM resource id, or None."""
    if not resource_id:
        return None
    return resource_id.rstrip("/").rsplit("/", 1)[-1] or None


def dig(obj, *path, default=None):
    """Walk nested dicts safely. ARM omits absent sub-objects entirely."""
    for key in path:
        if not isinstance(obj, dict):
            return default
        obj = obj.get(key)
        if obj is None:
            return default
    return obj


def tags_of(resource):
    """ARM tags, always a dict. Absent and empty are the same thing here."""
    tags = resource.get("tags")
    return tags if isinstance(tags, dict) else {}


# ── ARM client ─────────────────────────────────────────────────────────────────

class ArmError(Exception):
    """An error ARM reported, reduced to the two fields worth recording."""

    def __init__(self, status, code, message):
        super().__init__(f"{code}: {message}")
        self.status  = status
        self.code    = code
        self.message = message


class StaticTokenCredential:
    """A credential wrapping a token the caller already holds.

    Used when AZURE_ACCESS_TOKEN is set — the escape hatch for environments
    where the tool cannot sign in for itself: a CI job handed a token, a
    restricted jump host, or an operator who would rather run
    `az account get-access-token` under their own eyes than let a tool
    authenticate. The token is used exactly as given and never refreshed, so a
    scan outliving it fails loudly rather than silently losing subscriptions.
    """

    def __init__(self, token):
        self._token = token

    def get_token(self, *_scopes, **_kwargs):
        # Expiry is unknown from the token string alone. Claiming it is valid
        # lets the pipeline attach it; if it has in fact expired, ARM answers
        # 401 and the subscription is recorded as failed with that reason.
        return AccessToken(self._token, 253402300799)

    def close(self):
        pass


def build_credential(tenant_id):
    """The credential to sign ARM calls with.

    DefaultAzureCredential covers the ways a design partner is likely to be
    signed in already — az CLI, Azure PowerShell, environment variables,
    managed identity in Cloud Shell or on a VM, workload identity in AKS.
    """
    token = os.environ.get("AZURE_ACCESS_TOKEN")
    if token:
        log("Auth: using the token in AZURE_ACCESS_TOKEN")
        return StaticTokenCredential(token)
    kwargs = {}
    if tenant_id:
        # Both spellings matter: the first steers the interactive and CLI
        # credentials, the second steers the shared-cache one.
        kwargs["interactive_browser_tenant_id"] = tenant_id
        kwargs["shared_cache_tenant_id"]        = tenant_id
        kwargs["visual_studio_code_tenant_id"]  = tenant_id
    return DefaultAzureCredential(**kwargs)


def build_client(credential):
    """An ARM pipeline client with the retry policy this tool pins.

    Built by hand rather than taken from a service SDK so that the retry
    behaviour, the api-versions and the response shape are all set here and
    visible in one place. The tool reads raw ARM JSON: the generated SDK models
    reshape between major versions — v38 of azure-mgmt-compute moved every
    property under `.properties` and renders enums as `DiskState.ATTACHED`
    rather than `Attached` — and a discovery file whose field names depend on
    which SDK version the customer happened to install is not comparable
    between runs.
    """
    retry = RetryPolicy(
        # azure-core counts retries; MAX_ATTEMPTS counts attempts. See the
        # comment on MAX_ATTEMPTS.
        retry_total=MAX_ATTEMPTS - 1,
        retry_backoff_factor=RETRY_BACKOFF,
        retry_backoff_max=RETRY_BACKOFF_MAX,
        # 429 is the one that matters: ARM answers it with Retry-After when a
        # subscription's read quota is exhausted, which a tenant-wide scan does
        # routinely. Listed explicitly rather than relying on the default set,
        # for the same reason the AWS edition pins its retry mode.
        retry_on_status_codes=[408, 429, 500, 502, 503, 504],
    )
    # Order matters, and this is azure-core's own order (see PipelineClient's
    # default chain). Two parts of it are load-bearing rather than stylistic:
    #
    #  - Redirect sits *outside* the credential policy, so a redirect is
    #    re-authenticated for its new target instead of the original
    #    Authorization header being replayed at it.
    #  - SensitiveHeaderCleanupPolicy strips Authorization when a redirect
    #    crosses to a different host. Without it, an ARM endpoint that
    #    redirected off-host would be handed this identity's management-plane
    #    token.
    return PipelineClient(
        base_url=ARM_ENDPOINT,
        policies=[
            RequestIdPolicy(),
            HeadersPolicy(),
            UserAgentPolicy(base_user_agent=USER_AGENT),
            ProxyPolicy(),
            ContentDecodePolicy(),
            RedirectPolicy(),
            retry,
            BearerTokenCredentialPolicy(credential, ARM_SCOPE),
            DistributedTracingPolicy(),
            SensitiveHeaderCleanupPolicy(),
            HttpLoggingPolicy(),
        ],
    )


def arm_put(client, path, api_version, body):
    """One ARM PUT. Returns the decoded body, or raises ArmError."""
    request = HttpRequest(
        "PUT", f"{ARM_ENDPOINT}{path}",
        params={"api-version": api_version},
        json=body,
    )
    return _decode(client.send_request(request))


def arm_delete(client, path, api_version):
    """One ARM DELETE. A 204 means it was already gone, which is a success."""
    request = HttpRequest("DELETE", f"{ARM_ENDPOINT}{path}",
                          params={"api-version": api_version})
    response = client.send_request(request)
    if response.status_code == 204:
        return None
    return _decode(response)


def arm_get(client, path, api_version, params=None):
    """One ARM GET. Returns the decoded body, or raises ArmError.

    Extra query parameters arrive as a dict rather than keyword arguments
    because the ones ARM uses — "$expand", "$filter" — are not valid Python
    identifiers.
    """
    query = {"api-version": api_version}
    query.update({k: v for k, v in (params or {}).items() if v is not None})
    request = HttpRequest("GET", f"{ARM_ENDPOINT}{path}", params=query)
    return _decode(client.send_request(request))


def _decode(response):
    status = response.status_code
    try:
        body = response.json()
    except Exception:                                # noqa: BLE001 — body may not be JSON
        body = None

    if status >= 400:
        # ARM's documented error envelope is {"error": {"code", "message"}}, but
        # some providers answer with the inner object directly and a gateway in
        # front may answer with no JSON at all. Every one of those still has to
        # produce a code and a message rather than an unhandled exception.
        err  = dig(body, "error", default=body if isinstance(body, dict) else {}) or {}
        code = err.get("code") or f"Http{status}"
        message = err.get("message") or (response.reason or "no message")
        raise ArmError(status, code, message)

    if body is None:
        raise ArmError(status, "InvalidResponse", "ARM returned a body that is not JSON")
    return body


def arm_list(client, path, api_version, params=None):
    """Every page of an ARM list call, followed through nextLink.

    ARM paginates by handing back an absolute nextLink that already carries its
    own api-version and continuation token, so following it means re-sending it
    verbatim — adding parameters to it is how a paginated scan silently returns
    only its first page.
    """
    body  = arm_get(client, path, api_version, params)
    items = list(body.get("value") or [])
    pages = 1
    link  = body.get("nextLink")

    while link:
        if pages >= MAX_PAGES:
            raise ArmError(0, "TooManyPages",
                           f"list did not terminate after {MAX_PAGES} pages")
        if urlparse(link).scheme not in ("http", "https"):
            raise ArmError(0, "InvalidNextLink", f"nextLink is not an http(s) URL: {link[:120]}")
        body  = _decode(client.send_request(HttpRequest("GET", link)))
        items.extend(body.get("value") or [])
        link  = body.get("nextLink")
        pages += 1

    return items


# ── Shaping ARM resources into the output record ──────────────────────────────
# Every shaper reads the raw ARM JSON. Fields absent from a response stay None
# rather than being dropped, so a record has the same keys whichever provider
# version answered and a consumer can diff two runs field by field.

def shape_disk(d):
    props = d.get("properties") or {}
    return {
        "id":                d.get("id"),
        "name":              d.get("name"),
        "resource_group":    resource_group_of(d.get("id")),
        "location":          d.get("location"),
        "zones":             d.get("zones") or [],
        "sku_name":          dig(d, "sku", "name"),
        "sku_tier":          dig(d, "sku", "tier"),
        "size_gb":           props.get("diskSizeGB"),
        "state":             props.get("diskState"),
        "provisioning_state": props.get("provisioningState"),
        "iops":              props.get("diskIOPSReadWrite"),
        "mbps":              props.get("diskMBpsReadWrite"),
        "performance_tier":  props.get("tier"),
        "bursting_enabled":  props.get("burstingEnabled"),
        "os_type":           props.get("osType"),
        "encryption_type":   dig(props, "encryption", "type"),
        "create_option":     dig(props, "creationData", "createOption"),
        "source_resource_id": dig(props, "creationData", "sourceResourceId"),
        "created_at":        props.get("timeCreated"),
        # managedBy is the VM the disk is attached to, empty when unattached —
        # the distinction Datafy is being asked to scope, so it is lifted out of
        # the id rather than left for the reader to parse.
        "attached_to":       d.get("managedBy"),
        "attached_to_name":  name_of(d.get("managedBy")),
        "tags":              tags_of(d),
    }


def _power_state(props):
    """The VM's run state, from the instance view.

    Reported separately from provisioningState: a deallocated VM is still
    "Succeeded" provisioning-wise, and a stopped VM that still pays for its
    disks is exactly what a scoping run needs to see.
    """
    for status in dig(props, "instanceView", "statuses", default=[]) or []:
        code = status.get("code") or ""
        if code.startswith("PowerState/"):
            return code.split("/", 1)[1]
    return None


def _os_disk(props):
    os_disk = dig(props, "storageProfile", "osDisk") or {}
    if not os_disk:
        return None
    return {
        "name":          os_disk.get("name"),
        "os_type":       os_disk.get("osType"),
        "size_gb":       os_disk.get("diskSizeGB"),
        "caching":       os_disk.get("caching"),
        "create_option": os_disk.get("createOption"),
        "managed_disk_id": dig(os_disk, "managedDisk", "id"),
        "storage_account_type": dig(os_disk, "managedDisk", "storageAccountType"),
        # Set only on the unmanaged (page-blob) disks that predate Managed
        # Disks. Present in the record because a tenant still running them is a
        # material scoping finding, not an empty field.
        "vhd_uri":       dig(os_disk, "vhd", "uri"),
    }


def _data_disks(props):
    return [{
        "lun":           dd.get("lun"),
        "name":          dd.get("name"),
        "size_gb":       dd.get("diskSizeGB"),
        "caching":       dd.get("caching"),
        "create_option": dd.get("createOption"),
        "managed_disk_id": dig(dd, "managedDisk", "id"),
        "storage_account_type": dig(dd, "managedDisk", "storageAccountType"),
        "vhd_uri":       dig(dd, "vhd", "uri"),
    } for dd in (dig(props, "storageProfile", "dataDisks", default=[]) or [])]


def _image_reference(props):
    ref = dig(props, "storageProfile", "imageReference") or {}
    if not ref:
        return None
    return {
        "publisher":     ref.get("publisher"),
        "offer":         ref.get("offer"),
        "sku":           ref.get("sku"),
        "version":       ref.get("version"),
        "exact_version": ref.get("exactVersion"),
        "id":            ref.get("id"),
        "shared_gallery_image_id":    ref.get("sharedGalleryImageId"),
        "community_gallery_image_id": ref.get("communityGalleryImageId"),
    }


def shape_vm(v):
    props = v.get("properties") or {}
    return {
        "id":              v.get("id"),
        "name":            v.get("name"),
        "resource_group":  resource_group_of(v.get("id")),
        "location":        v.get("location"),
        "zones":           v.get("zones") or [],
        "vm_id":           props.get("vmId"),
        "vm_size":         dig(props, "hardwareProfile", "vmSize"),
        "provisioning_state": props.get("provisioningState"),
        "power_state":     _power_state(props),
        "os_type":         dig(props, "storageProfile", "osDisk", "osType"),
        "license_type":    props.get("licenseType"),
        "priority":        props.get("priority"),
        "eviction_policy": props.get("evictionPolicy"),
        "availability_set_id": dig(props, "availabilitySet", "id"),
        "scale_set_id":    dig(props, "virtualMachineScaleSet", "id"),
        "os_disk":         _os_disk(props),
        "data_disks":      _data_disks(props),
        "image_reference": _image_reference(props),
        "tags":            tags_of(v),
    }


def shape_scale_set(s):
    """A VM scale set.

    Collected because a Uniform-orchestration scale set's member VMs do not
    appear in the subscription's virtualMachines list at all — only their disks
    do. Without this, a tenant that runs most of its fleet in scale sets would
    show disks attached to machines the file never mentions.
    """
    props = s.get("properties") or {}
    profile = dig(props, "virtualMachineProfile", "storageProfile") or {}
    return {
        "id":             s.get("id"),
        "name":           s.get("name"),
        "resource_group": resource_group_of(s.get("id")),
        "location":       s.get("location"),
        "zones":          s.get("zones") or [],
        "sku_name":       dig(s, "sku", "name"),
        "sku_tier":       dig(s, "sku", "tier"),
        "capacity":       dig(s, "sku", "capacity"),
        "orchestration_mode": props.get("orchestrationMode"),
        "provisioning_state": props.get("provisioningState"),
        "os_type":        dig(profile, "osDisk", "osType"),
        "os_disk_size_gb": dig(profile, "osDisk", "diskSizeGB"),
        "os_disk_storage_account_type": dig(profile, "osDisk", "managedDisk", "storageAccountType"),
        "data_disks": [{
            "lun":     dd.get("lun"),
            "size_gb": dd.get("diskSizeGB"),
            "caching": dd.get("caching"),
            "storage_account_type": dig(dd, "managedDisk", "storageAccountType"),
        } for dd in (profile.get("dataDisks") or [])],
        "tags":           tags_of(s),
    }


def shape_snapshot(s):
    props = s.get("properties") or {}
    return {
        "id":               s.get("id"),
        "name":             s.get("name"),
        "resource_group":   resource_group_of(s.get("id")),
        "location":         s.get("location"),
        "sku_name":         dig(s, "sku", "name"),
        "sku_tier":         dig(s, "sku", "tier"),
        "size_gb":          props.get("diskSizeGB"),
        "state":            props.get("diskState"),
        "incremental":      props.get("incremental"),
        "os_type":          props.get("osType"),
        "encryption_type":  dig(props, "encryption", "type"),
        "create_option":    dig(props, "creationData", "createOption"),
        "source_resource_id": dig(props, "creationData", "sourceResourceId"),
        # The disk this snapshot came from, which is what makes a snapshot
        # attributable to the volume it is protecting.
        "source_disk_name": name_of(dig(props, "creationData", "sourceResourceId")),
        "created_at":       props.get("timeCreated"),
        "tags":             tags_of(s),
    }


def shape_image(i):
    props = i.get("properties") or {}
    os_disk = dig(props, "storageProfile", "osDisk") or {}
    return {
        "id":             i.get("id"),
        "name":           i.get("name"),
        "resource_group": resource_group_of(i.get("id")),
        "location":       i.get("location"),
        "provisioning_state": props.get("provisioningState"),
        "hyper_v_generation": props.get("hyperVGeneration"),
        "source_virtual_machine_id": dig(props, "sourceVirtualMachine", "id"),
        "os_type":        os_disk.get("osType"),
        "os_state":       os_disk.get("osState"),
        "os_disk_size_gb": os_disk.get("diskSizeGB"),
        "data_disk_count": len(dig(props, "storageProfile", "dataDisks", default=[]) or []),
        "tags":           tags_of(i),
    }


def shape_vault(v, vault_type):
    return {
        "id":             v.get("id"),
        "name":           v.get("name"),
        "resource_group": resource_group_of(v.get("id")),
        "location":       v.get("location"),
        "vault_type":     vault_type,
        "sku_name":       dig(v, "sku", "name"),
        "tags":           tags_of(v),
    }


def shape_policy(p, vault, vault_type):
    """A backup policy, kept alongside the vault it belongs to.

    The two vault families are reported in one list with vault_type telling them
    apart: Recovery Services vaults hold the classic VM backup policies, and
    Data Protection backup vaults hold the newer per-disk ones. Which family a
    customer uses is itself a scoping finding, so neither is folded into the
    other.
    """
    props = p.get("properties") or {}
    return {
        "id":             p.get("id"),
        "name":           p.get("name"),
        "vault_id":       vault.get("id"),
        "vault_name":     vault.get("name"),
        "vault_type":     vault_type,
        "resource_group": resource_group_of(p.get("id")),
        "backup_management_type": props.get("backupManagementType"),
        "datasource_types":       props.get("datasourceTypes"),
        "policy_type":            props.get("policyType") or props.get("objectType"),
        "protected_items_count":  props.get("protectedItemsCount"),
    }


# ── Per-subscription scan ──────────────────────────────────────────────────────

def subscription_record(sub, status, reason=None, **extra):
    """The skeleton every subscription record shares.

    A subscription that could not be read still gets a record, with a status and
    a reason, so a missing subscription is visible in the file the customer
    sends us rather than only in a log they redirected away.
    """
    record = {
        "record_type":       "subscription",
        "subscription_id":   sub.get("subscription_id"),
        "subscription_name": sub.get("display_name"),
        "tenant_id":         sub.get("tenant_id"),
        "subscription_state": sub.get("state"),
        "status":            status,
        "reason":            reason,
        "scanned_at":        now_utc(),
        "errors":            [],
        "locations":         [],
        "disks":             [],
        "virtual_machines":  [],
        "scale_sets":        [],
        "snapshots":         [],
        "images":            [],
        "backup_vaults":     [],
        "backup_policies":   [],
    }
    record.update(extra)
    return record


def scan_subscription(client, sub):
    """
    Collect all discovery data for one subscription. Always returns a record.

    Every ARM call is attempted independently and its failure recorded, so the
    record distinguishes a subscription that is genuinely empty from one whose
    reads were denied. This is the whole reason the tool reports a status per
    subscription rather than letting an exception delete it from the output.

    Azure differs from AWS here in where a failure lands. ARM list calls are
    scoped to a subscription and return every region at once, so a denied read
    costs a whole subscription rather than one region — which is why the record
    is per subscription, and why each resource carries its own location.
    """
    sub_id = sub["subscription_id"]
    base   = f"/subscriptions/{sub_id}/providers"
    errors = []
    stats  = {"calls": 0, "failures": 0}
    lock   = threading.Lock()

    def attempt(api, fn, default):
        with lock:
            stats["calls"] += 1
        try:
            return fn()
        except Exception as e:                       # noqa: BLE001 — any failure must be reported
            with lock:
                stats["failures"] += 1
                errors.append(f"{api}: {condense(e)}")
            return default

    def simple(api_name, provider_path, api_key, shaper):
        return [shaper(x) for x in attempt(
            api_name,
            lambda: arm_list(client, f"{base}/{provider_path}", API[api_key]),
            [],
        )]

    def list_disks():
        return simple("Microsoft.Compute/disks", "Microsoft.Compute/disks", "disks", shape_disk)

    def list_snapshots():
        return simple("Microsoft.Compute/snapshots", "Microsoft.Compute/snapshots", "snapshots", shape_snapshot)

    def list_images():
        return simple("Microsoft.Compute/images", "Microsoft.Compute/images", "images", shape_image)

    def list_scale_sets():
        return simple("Microsoft.Compute/virtualMachineScaleSets",
                      "Microsoft.Compute/virtualMachineScaleSets", "scale_sets", shape_scale_set)

    def list_vms():
        """VMs, with run-time power state merged in from a second pass.

        power_state lives in the instance view, and a stopped VM still paying
        for its disks is precisely what a scoping run is looking for. ARM will
        not expand it inline at subscription scope, though — `$expand=
        instanceView` there is rejected outright ("Expand Instance View is only
        supported when Virtual Machine Scale Set resource filter is applied"),
        because the expand is only honoured for a scale-set-filtered query. The
        supported route for a whole subscription is a separate pass with
        statusOnly=true, which returns each VM's instance view and nothing else.

        So the inventory call goes out plain, and first: it is the one that must
        not be lost. If the status pass then fails, every VM is still reported
        with power_state null, and the subscription is marked partial with the
        reason — losing run state is a far smaller loss than losing the fleet.

        Only `id` and the instance view are read back from the status pass. It
        is documented to return run-time status rather than a second full copy
        of each VM, so nothing here depends on the rest of that payload.
        """
        path = f"{base}/Microsoft.Compute/virtualMachines"
        vms = [shape_vm(v) for v in attempt(
            "Microsoft.Compute/virtualMachines",
            lambda: arm_list(client, path, API["virtual_machines"]),
            [],
        )]
        if not vms:
            return vms

        statuses = attempt(
            "Microsoft.Compute/virtualMachines?statusOnly=true",
            lambda: arm_list(client, path, API["virtual_machines"], {"statusOnly": "true"}),
            [],
        )
        # Resource ids are compared case-insensitively: ARM echoes back whatever
        # casing a resource was created with, and the two passes are not
        # guaranteed to agree on it.
        power = {
            (v.get("id") or "").lower(): _power_state(v.get("properties") or {})
            for v in statuses
        }
        for vm in vms:
            vm["power_state"] = power.get((vm["id"] or "").lower())
        return vms

    def list_backup():
        """Vaults and their policies, from both of Azure's backup families.

        Policies are vault-scoped in ARM — there is no subscription-wide list —
        so this is one call per vault. A vault whose policies are denied still
        appears in backup_vaults with the failure recorded against the
        subscription, rather than removing the vault from the file.
        """
        vaults, policies = [], []

        families = [
            ("RecoveryServices", "Microsoft.RecoveryServices/vaults",
             "rsv_vaults", "rsv_policies"),
            ("DataProtection", "Microsoft.DataProtection/backupVaults",
             "dp_vaults", "dp_policies"),
        ]

        for vault_type, provider_path, vaults_key, policies_key in families:
            found = attempt(
                provider_path,
                lambda p=provider_path, k=vaults_key: arm_list(client, f"{base}/{p}", API[k]),
                [],
            )
            for vault in found:
                vaults.append(shape_vault(vault, vault_type))
                rg, name = resource_group_of(vault.get("id")), vault.get("name")
                if not rg or not name:
                    continue
                policy_path = (f"/subscriptions/{sub_id}/resourceGroups/{rg}"
                               f"/providers/{provider_path}/{name}/backupPolicies")
                found_policies = attempt(
                    f"{provider_path}/{name}/backupPolicies",
                    lambda p=policy_path, k=policies_key: arm_list(client, p, API[k]),
                    [],
                )
                policies.extend(shape_policy(p, vault, vault_type) for p in found_policies)

        return {"backup_vaults": vaults, "backup_policies": policies}

    # The five resource lists are independent of one another, so they go out
    # together rather than one at a time. The outer pool already keeps 20
    # subscriptions in flight; this is what keeps a tenant of two very large
    # subscriptions from being scanned essentially serially.
    tasks = {
        "disks":            list_disks,
        "virtual_machines": list_vms,
        "scale_sets":       list_scale_sets,
        "snapshots":        list_snapshots,
        "images":           list_images,
        "backup":           list_backup,
    }

    collected = {}
    with ThreadPoolExecutor(max_workers=MAX_CALL_WORKERS) as pool:
        futures = {pool.submit(fn): key for key, fn in tasks.items()}
        for future in as_completed(futures):
            key = futures[future]
            try:
                result = future.result()
            except Exception as e:                   # noqa: BLE001 — a shaper bug must not delete the subscription
                with lock:
                    stats["failures"] += 1
                    errors.append(f"{key}: collection failed unexpectedly: {condense(e)}")
                result = {} if key == "backup" else []
            if key == "backup":
                collected.update(result)
            else:
                collected[key] = result

    if stats["failures"] == 0:
        status = "ok"
    elif stats["failures"] >= stats["calls"]:
        status = "failed"
    else:
        status = "partial"

    # Every location the subscription actually has something in. A scoping
    # conversation starts with "which regions are you in", and answering it from
    # the file should not mean unioning six arrays by hand.
    locations = {
        item.get("location")
        for key in ("disks", "virtual_machines", "scale_sets", "snapshots", "images", "backup_vaults")
        for item in collected.get(key, [])
        if item.get("location")
    }

    return subscription_record(
        sub, status,
        errors=sorted(set(errors)),
        locations=sorted(locations),
        **{k: collected.get(k, []) for k in (
            "disks", "virtual_machines", "scale_sets", "snapshots",
            "images", "backup_vaults", "backup_policies")},
    )


# ── Subscription list ──────────────────────────────────────────────────────────

def _normalize_subscription(s):
    return {
        "subscription_id": s.get("subscriptionId"),
        "display_name":    s.get("displayName"),
        "state":           s.get("state"),
        "tenant_id":       s.get("tenantId"),
    }


def management_group_subscriptions(client, group_id):
    """Subscription ids anywhere beneath a management group.

    /descendants walks the whole subtree, so a nested management group's
    subscriptions are included — which is what an operator naming their
    top-level "Production" group means. The response mixes child management
    groups in with subscriptions, hence the type filter.
    """
    items = arm_list(
        client,
        f"/providers/Microsoft.Management/managementGroups/{group_id}/descendants",
        API["descendants"],
    )
    return {
        item.get("name")
        for item in items
        if (item.get("type") or "").lower().endswith("/subscriptions") and item.get("name")
    }


def _tenant_roots(subs, tenant, hint=None):
    """Tenant ids whose hierarchy is worth asking about.

    The tenant root management group's id is the tenant id, so the tenants the
    visible subscriptions belong to are the roots to check.

    `hint` — the tenant from the access token — covers the case that matters
    most and is easiest to miss: an identity that can see no subscriptions at
    all has no tenant to derive from them, which is exactly when knowing what it
    is missing is worth the most.
    """
    if tenant:
        return [tenant]
    roots = sorted({s["tenant_id"] for s in subs if s["tenant_id"]})
    if not roots and hint:
        return [hint]
    return roots


def token_tenant_hint(credential):
    """The tenant id from the access token, or None.

    Best effort, and never fatal: it is used only to know which tenant root
    management group to ask about when the subscription list cannot name one.
    A scan works without it — it just cannot vouch for its own scope.
    """
    try:
        return _token_claims(credential.get_token(ARM_SCOPE).token).get("tid")
    except Exception:                                # noqa: BLE001
        return None


def list_subscriptions(client, tenant, management_group, include, exclude,
                       tenant_hint=None):
    """What to scan, what is known to be missing, and whether that is knowable.

    Returns (scannable, unreachable, scope).

    The hard part in Azure is the denominator. `GET /subscriptions` returns only
    the subscriptions the identity can already see — a subscription no role
    assignment reaches is not listed as denied, it is simply absent. So unlike
    AWS, where organizations:ListAccounts names every account in the org whether
    or not it can be assumed into, this call cannot on its own tell a complete
    scan from a half-granted one. Left alone it would report
    "3 total, 3 scanned, 0 failed" for a tenant of two hundred.

    The management group hierarchy is the denominator, because it lists
    subscriptions by membership rather than by access. Anything in it that
    `/subscriptions` did not return is a subscription this identity cannot
    reach, and is returned in `unreachable` so it lands in the output file with
    a reason rather than vanishing.

    When the hierarchy cannot be read either, no denominator is available and
    the run genuinely cannot vouch for its own completeness. That is reported as
    `scope.verified = False` and carried into the summary record, so the file
    says so rather than implying coverage it never established.
    """
    try:
        subs = [_normalize_subscription(s)
                for s in arm_list(client, "/subscriptions", API["subscriptions"])]
    except Exception as e:                           # noqa: BLE001
        if not include:
            raise
        log(f"  [warn] could not list subscriptions ({condense(e)}); "
            "scanning the --include ids without their names")
        subs = [{"subscription_id": s, "display_name": None,
                 "state": None, "tenant_id": None} for s in include]

    if tenant:
        subs = [s for s in subs if not s["tenant_id"] or s["tenant_id"] == tenant]

    visible     = {s["subscription_id"] for s in subs}
    unreachable = []
    scope       = {"verified": False, "note": None}

    if management_group:
        # The group is the scope, so it is also the denominator.
        in_group = management_group_subscriptions(client, management_group)
        subs = [s for s in subs if s["subscription_id"] in in_group]
        for missing in sorted(in_group - visible):
            unreachable.append((missing, (
                f"in management group {management_group}, but not visible to this "
                "identity — no role assignment reaches it")))
        scope = {"verified": True,
                 "note": f"scope checked against management group {management_group}"}

    elif include:
        # An explicit list is its own denominator: the operator said what they
        # expected, so anything they named and we cannot see is a gap.
        scope = {"verified": True, "note": "scope checked against --include"}

    else:
        # Whole-tenant run. Ask the tenant root management group what exists.
        expected, failures, checked = set(), [], []
        for root in _tenant_roots(subs, tenant, tenant_hint):
            try:
                expected |= management_group_subscriptions(client, root)
                checked.append(root)
            except Exception as e:                   # noqa: BLE001
                failures.append(f"tenant {root}: {condense(e)}")

        for missing in sorted(expected - visible):
            unreachable.append((missing, (
                "in the tenant hierarchy, but not visible to this identity — "
                "no role assignment reaches it")))

        if checked and not failures:
            scope = {"verified": True,
                     "note": "scope checked against the tenant root management group"}
        else:
            detail = "; ".join(failures) or "no tenant could be determined from the subscription list"
            scope = {"verified": False, "note": (
                "scope NOT checked against the tenant root management group "
                f"({detail}). Subscriptions this identity cannot see are absent from "
                "this file and are not counted below — do not read these totals as "
                "full tenant coverage.")}

    if include:
        wanted = set(include)
        subs = [s for s in subs if s["subscription_id"] in wanted]
        already = {sub_id for sub_id, _ in unreachable}
        # Named and not visible. Recorded, not merely warned about: a warning on
        # stderr is gone the moment the operator redirects it, and the file is
        # the only thing that gets sent to us.
        for missing in sorted(wanted - visible - already):
            unreachable.append((missing, (
                "named by --include, but not visible to this identity — "
                "no role assignment reaches it")))

    subs        = [s for s in subs if s["subscription_id"] not in exclude]
    unreachable = [(i, r) for i, r in unreachable if i not in exclude]
    subs.sort(key=lambda s: s["subscription_id"] or "")
    unreachable.sort()
    return subs, unreachable, scope


# ── Reader access setup (--setup-role) ────────────────────────────────────────
# The Azure counterpart of the AWS edition's CloudFormation StackSet. Same
# contract: grant the access the scan needs, scan, then always take it away
# again — including when the scan fails.
#
# It is a far smaller thing than the AWS one, because Azure RBAC inherits. AWS
# has to deploy a role into every member account and tear N of them down again;
# here a single assignment at a tenant root management group covers every
# subscription beneath it, present and future. One PUT, one DELETE.
#
# This is also the only part of the tool that writes anything.


def _token_claims(token):
    """The claims inside a JWT, without verifying it.

    Only ever used to read our own access token's `oid` — the object id of the
    principal ARM will be granting the role to. The token was just handed to us
    by our own credential and is about to be sent back to the issuer, which does
    verify it. Nothing here is a trust decision.
    """
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception as e:                           # noqa: BLE001
        raise RuntimeError(f"could not read the access token's claims: {condense(e)}")


def token_identity(credential):
    """The (principal object id, tenant id) this tool is running as.

    Both are read from the access token rather than from Microsoft Graph, which
    would mean another dependency, another consent prompt and another permission
    to document — for two values the token already carries.

    The tenant has to come from here rather than from the subscription list,
    which is the trap: an identity with no role assignments anywhere sees an
    empty /subscriptions, so deriving the tenant from it fails in exactly the
    situation --setup-role exists to fix.
    """
    claims = _token_claims(credential.get_token(ARM_SCOPE).token)
    oid = claims.get("oid")
    if not oid:
        raise RuntimeError(
            "the access token carries no 'oid' claim, so the identity to grant "
            "Reader to cannot be determined. Sign in as a user or service "
            "principal, or grant Reader yourself and run without --setup-role.")
    return oid, claims.get("tid")


def _assignment_path(scope, name):
    return f"{scope}/providers/Microsoft.Authorization/roleAssignments/{name}"


def grant_reader(client, scope, principal):
    """Assign Reader to `principal` at `scope`.

    Returns True if this call created the assignment, False if an equivalent one
    was already there. The distinction is load-bearing: teardown removes only
    what this run created, so a standing grant that happens to match is never
    revoked out from under the customer. (The AWS edition is less careful here —
    it deletes the StackSet even when it reused a pre-existing one.)
    """
    name = str(uuid.uuid5(ASSIGNMENT_NAMESPACE, f"{scope}|{principal}"))
    body = {"properties": {
        "roleDefinitionId": f"/providers/Microsoft.Authorization/roleDefinitions/{READER_ROLE_ID}",
        "principalId":      principal,
    }}
    try:
        arm_put(client, _assignment_path(scope, name), API["role_assignments"], body)
        return True
    except ArmError as e:
        if e.code in ("RoleAssignmentExists", "RoleAssignmentUpdateNotPermitted"):
            log(f"  Reader is already assigned at {scope} — leaving it alone.")
            return False
        raise


def revoke_reader(client, scope, principal):
    name = str(uuid.uuid5(ASSIGNMENT_NAMESPACE, f"{scope}|{principal}"))
    arm_delete(client, _assignment_path(scope, name), API["role_assignments"])


def wait_for_propagation(client, expected):
    """Block until the new access is actually usable, or the timeout expires.

    Azure does not make a role assignment effective the moment it is written.
    Scanning straight away would miss precisely the subscriptions --setup-role
    was used to reach, and would report them unreachable — a failure that looks
    exactly like the flag not working, immediately after it did.

    `expected` is what the management group hierarchy says should become
    visible. Polling stops as soon as /subscriptions has caught up with it.
    """
    if not expected:
        return True
    deadline = time.time() + PROPAGATION_TIMEOUT
    while True:
        try:
            visible = {s.get("subscriptionId")
                       for s in arm_list(client, "/subscriptions", API["subscriptions"])}
        except Exception as e:                       # noqa: BLE001
            visible = set()
            log(f"  [warn] could not re-check visible subscriptions: {condense(e)}")

        missing = expected - visible
        if not missing:
            log(f"  Reader is in effect across {len(expected)} subscription(s).")
            return True
        if time.time() >= deadline:
            log(f"  [warn] {len(missing)} subscription(s) still not visible after "
                f"{PROPAGATION_TIMEOUT:.0f}s. Scanning anyway — every one of them is "
                "recorded in the output with a reason.")
            return False
        log("  Waiting for the role assignment to take effect "
            f"({len(expected) - len(missing)}/{len(expected)} visible)...")
        time.sleep(PROPAGATION_POLL)


def setup_reader_access(client, credential, tenant, management_group):
    """Grant Reader everywhere this run needs it. Returns what to revoke later.

    The scope is always a management group, never a subscription, and that is
    the point: assigning at a tenant root covers every subscription beneath it,
    so a subscription the identity could not previously see becomes readable
    without having to be enumerated first. It could not have been enumerated —
    a subscription no assignment reaches is absent from /subscriptions entirely.
    """
    principal, token_tenant = token_identity(credential)
    log(f"Granting Reader to principal {principal}...")

    if management_group:
        groups = [management_group]
    else:
        # --tenant first if given, then the token's own tenant. Deliberately not
        # the subscription list: an identity with no assignments anywhere sees
        # nothing there, and that is the case this flag is for.
        groups = [g for g in (tenant, token_tenant) if g][:1]
        if not groups:
            raise RuntimeError(
                "no tenant could be determined to grant Reader in — the access token "
                "carries no 'tid' claim. Pass --tenant, or --management-group, to name "
                "the scope explicitly.")

    granted, expected = [], set()
    for group in groups:
        scope = f"/providers/Microsoft.Management/managementGroups/{group}"
        if grant_reader(client, scope, principal):
            granted.append((scope, principal))
            log(f"  Reader assigned at {scope}")
        try:
            expected |= management_group_subscriptions(client, group)
        except Exception as e:                       # noqa: BLE001
            log(f"  [warn] could not read the hierarchy under {scope}: {condense(e)}")

    if granted:
        wait_for_propagation(client, expected)
    return granted


def teardown_reader_access(client, granted):
    """Remove every assignment this run created. Never raises.

    Called from a finally block, so it has to survive whatever went wrong
    upstream — and a failure to clean up has to be shouted about rather than
    raised, since raising here would replace the real error with this one.
    """
    for scope, principal in granted:
        try:
            revoke_reader(client, scope, principal)
            log(f"Reader assignment removed from {scope}")
        except Exception as e:                       # noqa: BLE001
            log(f"  [warn] could not remove the Reader assignment at {scope}: {condense(e)}")
            log(f"  Remove it by hand: az role assignment delete --assignee {principal} "
                f"--role Reader --scope {scope}")


# ── Entry point ────────────────────────────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            f"Datafy Discovery Tool (Azure) v{VERSION} — inventories managed disks, virtual "
            "machines, snapshots, images and backup policies across an Azure tenant. "
            "Read-only, unless --setup-role is used. Safe to run in production."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--version", action="version",
                        version=f"Datafy Discovery Tool (Azure) v{VERSION}")
    parser.add_argument(
        "--setup-role", action="store_true",
        help=(
            "Assign the built-in Reader role to the signed-in identity at the tenant "
            "root management group (or at --management-group), wait for it to take "
            "effect, scan, then always remove it again. Requires permission to create "
            "role assignments — Owner, User Access Administrator or Role Based Access "
            "Control Administrator. Without this flag the tool writes nothing and scans "
            "with whatever access the identity already has."
        ),
    )
    parser.add_argument("--tenant", metavar="TENANT_ID",
                        help="Limit to subscriptions in this Microsoft Entra tenant")
    parser.add_argument("--management-group", metavar="MG_ID",
                        help="Limit to subscriptions beneath this management group, nested ones included")
    parser.add_argument("--include", metavar="ID1,ID2,...",
                        help="Comma-separated subscription IDs to scan (instead of all)")
    parser.add_argument("--exclude", metavar="ID1,ID2,...",
                        help="Comma-separated subscription IDs to skip")
    parser.add_argument("--output", metavar="FILE",
                        help="Output file path (default: discovery_azure_<timestamp>.json)")
    return parser.parse_args()


def main():
    args = parse_args()

    # Route SIGTERM through the same path as Ctrl+C, so a run killed by a
    # timeout or a supervisor still writes out what it has collected. Which
    # signal arrived is remembered so the process can exit 128+signal: a
    # supervising script has to be able to tell an interrupted run from a clean
    # one, and exiting 0 after an interrupt claims coverage the scan never had.
    interrupt_signal = [signal.SIGINT]

    def _on_sigterm(signum, _frame):
        interrupt_signal[0] = signum
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, _on_sigterm)

    include = [s.strip() for s in args.include.split(",") if s.strip()] if args.include else []
    exclude = {s.strip() for s in args.exclude.split(",") if s.strip()} if args.exclude else set()

    log(f"Datafy Discovery Tool (Azure) v{VERSION}")
    if ARM_ENDPOINT != "https://management.azure.com":
        log(f"ARM endpoint:        {ARM_ENDPOINT}")

    credential = build_credential(args.tenant)
    client     = build_client(credential)

    # --setup-role is the only path in this tool that writes anything. Whatever
    # happens afterwards — a failed scan, an interrupt, an unwritable --output —
    # the assignment it created has to come back off, so the scan runs inside a
    # try/finally exactly the way the AWS edition's StackSet does. sys.exit
    # raises SystemExit, which a finally still runs on, so even the early exits
    # clean up after themselves.
    granted = []
    try:
        if args.setup_role:
            try:
                granted = setup_reader_access(
                    client, credential, args.tenant, args.management_group)
            except Exception as e:                   # noqa: BLE001
                print(
                    f"Error: --setup-role could not grant Reader — {condense(e)}\n\n"
                    "Creating a role assignment needs Owner, User Access Administrator or\n"
                    "Role Based Access Control Administrator at the scope. Assigning at a\n"
                    "tenant root management group additionally needs the Global Administrator\n"
                    "to have elevated access at least once — see README.md, 'Permissions'.\n\n"
                    "Run without --setup-role to scan with the access you already have.",
                    file=sys.stderr)
                sys.exit(1)
        run_scan(client, args, include, exclude, interrupt_signal,
                 token_tenant_hint(credential))
    finally:
        teardown_reader_access(client, granted)


def run_scan(client, args, include, exclude, interrupt_signal, tenant_hint=None):
    """Enumerate, scan and write the output file.

    Assumes whatever access the run is going to get is already in place, so that
    granting it and using it stay separable — and so that the ordinary,
    write-nothing path is the same code as the --setup-role one.
    """
    try:
        subscriptions, unreachable, scope = list_subscriptions(
            client, args.tenant, args.management_group, include, exclude,
            tenant_hint)
    except ClientAuthenticationError as e:
        print(
            f"Error: could not authenticate to Azure — {condense(e)}\n\n"
            "Sign in using one of:\n"
            "  az login                                     (Azure CLI — simplest)\n"
            "  az login --tenant <tenant-id>                (a specific tenant)\n"
            "  export AZURE_CLIENT_ID=... AZURE_TENANT_ID=... AZURE_CLIENT_SECRET=...\n"
            "                                               (service principal)\n"
            "  export AZURE_ACCESS_TOKEN=$(az account get-access-token \\\n"
            "           --query accessToken -o tsv)         (a token you already hold)\n\n"
            "Running inside Azure Cloud Shell or on a VM with a managed identity needs "
            "no sign-in step at all.",
            file=sys.stderr,
        )
        sys.exit(1)
    except Exception as e:                           # noqa: BLE001
        print(f"Error: could not determine which subscriptions to scan — {condense(e)}\n\n"
              "The identity needs Reader on the subscriptions you want scanned, and on the "
              "management group if --management-group was used — see README.md, "
              "'Permissions'.", file=sys.stderr)
        sys.exit(1)

    # A subscription Azure does not report as Enabled cannot be read, and saying
    # so up front is more useful than six identical AuthorizationFailed errors.
    def is_enabled(sub):
        # A subscription the list call could not name a state for — the
        # --include fallback path — is given the benefit of the doubt and
        # scanned; ARM will say so if it is wrong.
        return (sub["state"] or "Enabled") == "Enabled"

    scannable = [s for s in subscriptions if is_enabled(s)]
    disabled  = [s for s in subscriptions if not is_enabled(s)]

    log(f"\nSubscriptions to scan: {len(scannable)}")
    if disabled:
        log(f"Subscriptions not enabled, recorded as skipped: {len(disabled)}")
    if unreachable:
        log(f"Subscriptions this identity cannot read, recorded as failed: {len(unreachable)}")
        for sub_id, reason in unreachable:
            log(f"  [gap] {sub_id}: {reason}")
        log("  Grant Reader at the tenant root management group to cover them — "
            "see README.md, 'Permissions'.")
    if not scope["verified"]:
        # Loud, because it is the one thing that cannot be recovered from the
        # file afterwards: what is absent is absent without trace.
        log(f"\n  [warn] {scope['note']}")

    output_file = args.output or f"discovery_azure_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"

    # Checked up front — a scan that cannot write its results is worth failing
    # immediately, not after an hour of API calls. The message names the path:
    # an unhandled OSError tells the operator the tool broke, not that their
    # --output argument is wrong.
    try:
        out_file = open(output_file, "w")
    except OSError as e:
        print(f"Error: cannot write output file '{output_file}' — {e.strerror}. "
              "Check the directory exists and is writable.", file=sys.stderr)
        sys.exit(1)

    tally = {"ok": 0, "partial": 0, "failed": 0, "skipped": 0}
    interrupted = False
    done = 0

    def emit(record):
        out_file.write(json.dumps(record) + "\n")
        tally[record["status"]] = tally.get(record["status"], 0) + 1

    with out_file as out:
        for sub in disabled:
            emit(subscription_record(
                sub, "skipped",
                f"subscription state is {sub['state']!r}, not 'Enabled'"))

        # Subscriptions the hierarchy says exist but this identity cannot read.
        # Recorded rather than dropped: an unreachable subscription that leaves
        # no trace in the file is the one failure the customer cannot see and we
        # cannot ask about.
        for sub_id, reason in unreachable:
            emit(subscription_record(
                {"subscription_id": sub_id, "display_name": None,
                 "state": None, "tenant_id": args.tenant},
                "failed", reason))

        # Records are written as each subscription completes, so an interrupted
        # run keeps everything already collected — a large tenant can easily be
        # Ctrl+C'd or killed by a timeout.
        recorded = set()
        futures = {}
        pool = ThreadPoolExecutor(max_workers=MAX_SUBSCRIPTION_WORKERS)
        try:
            futures = {pool.submit(scan_subscription, client, s): s for s in scannable}
            for future in as_completed(futures):
                sub = futures[future]
                try:
                    record = future.result()
                except Exception as e:               # noqa: BLE001
                    reason = f"subscription scan failed unexpectedly: {condense(e)}"
                    log(f"  [fail] {sub['subscription_id']}: {reason}")
                    record = subscription_record(sub, "failed", reason)
                emit(record)
                recorded.add(sub["subscription_id"])
                done += 1
                log(f"  [{done}/{len(scannable)}] {sub['subscription_id']} — "
                    f"{record['status']}, {len(record['disks'])} disks, "
                    f"{len(record['virtual_machines'])} VMs")
                for err in record["errors"]:
                    log(f"         {sub['subscription_id']}: {err}")
        except KeyboardInterrupt:
            interrupted = True
            log("\nInterrupted — writing out the results collected so far...")
            # Subscriptions still queued can be dropped outright; ones already
            # running cannot be cancelled and are waited for below. Without the
            # cancel, shutdown would work through the entire remaining queue
            # before the interrupt took effect — on a large tenant that is the
            # difference between stopping now and stopping in an hour.
            for pending in futures:
                pending.cancel()
        finally:
            pool.shutdown(wait=True)

        # Subscriptions that never produced a record are still named, so the gap
        # is visible in the file rather than only in the tallies.
        if interrupted:
            for sub in scannable:
                if sub["subscription_id"] not in recorded:
                    emit(subscription_record(
                        sub, "failed", "run interrupted before this subscription finished"))

        summary = {
            "record_type":             "summary",
            "tool_version":            VERSION,
            "cloud":                   "azure",
            "scanned_at":              now_utc(),
            "interrupted":             interrupted,
            # False when the run could not establish what the tenant contains,
            # so the totals below are "what was visible", not "what exists".
            "scope_verified":          scope["verified"],
            "scope_note":              scope["note"],
            "subscriptions_total":     len(subscriptions) + len(unreachable),
            "subscriptions_scanned":   tally["ok"],
            "subscriptions_partial":   tally["partial"],
            "subscriptions_failed":    tally["failed"],
            "subscriptions_skipped":   tally["skipped"],
        }
        out.write(json.dumps(summary) + "\n")

    if interrupted:
        log("\nRun was interrupted — the results below are partial.")
    log(f"\nSubscriptions: {summary['subscriptions_total']} total, "
        f"{summary['subscriptions_scanned']} scanned, "
        f"{summary['subscriptions_partial']} partial, "
        f"{summary['subscriptions_failed']} failed, "
        f"{summary['subscriptions_skipped']} skipped")
    log(f"Output:   {output_file}")
    if any(summary[k] for k in ("subscriptions_partial", "subscriptions_failed",
                                "subscriptions_skipped")):
        log("\nSome subscriptions were not fully scanned. Every one is recorded in")
        log(f"{output_file} with a status and a reason — send the file as-is.")
    if not scope["verified"]:
        log("\nCoverage could not be verified: the totals above count only what this")
        log("identity can see, which may be less than the tenant contains. The summary")
        log("record carries scope_verified=false so the file says so too.")

    # Conventional 128+signal, matching the AWS edition, so a wrapper can tell
    # an interrupted run from a complete one. The results written above are
    # still valid — just partial.
    if interrupted:
        sys.exit(128 + interrupt_signal[0])


if __name__ == "__main__":
    main()
