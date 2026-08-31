#!/usr/bin/env python3
"""
A fake AWS endpoint shared by every test in this directory.

The three discovery implementations talk to AWS through three different clients
— the AWS CLI, boto3, and aws-sdk-go-v2 — so mocking at the client level can
only ever test one of them. All three honour AWS_ENDPOINT_URL, so pointing them
at a single server here exercises the real clients, the real signing and the
real pagination, and lets one set of test cases run against all three.

Routing: every service lands on one host, so a request is classified by the
service name in the SigV4 credential scope
(`Credential=AK/20260101/us-east-1/ec2/aws4_request`). Signatures are not
verified — the point is protocol shape, not auth.

Which account a request belongs to is read from the access key id: AssumeRole
hands back "AKIAMOCK<account-id>", which the client then signs with.

Scenario (a JSON file named by FAKE_AWS_SCENARIO):

    {
      "caller_account": "000000000000",
      "accounts":       ["000000000000", "111111111111"],
      "regions":        ["us-east-1", "eu-west-1"],

      "volumes": 3, "instances": 2, "snapshots": 2, "ami_count": 3,
      "tag_pad": 0,            bytes of filler per tag value, to inflate payloads

      "deny_assume": ["222222222222"],
      "deny": {                account/region -> denied actions, "*" for all
        "111111111111/eu-west-1": ["DescribeVolumes"],
        "444444444444/eu-west-1": ["*"]
      },

      "delay_seconds": 20,     hold every data call open this long...
      "delay_accounts": [],    ...for these accounts (default: all)

      "expire_after": 12,      after N data calls org-wide, the rest fail
                               with ExpiredToken

      "throttle": {            reject this many attempts of an action before
        "DescribeVolumes": 2   answering it, counted per account/region/action —
      },                       models a burst the client should ride out
      "throttle_forever": [    actions throttled on every attempt, so the
        "DescribeSnapshots"    client exhausts its retries and gives up
      ],

      "corrupt": {             region -> actions that return an unparseable body
        "us-east-1": ["DescribeVolumes"]
      },

      "page_size": 100,        paginate result sets at this size (0 = one page)
      "max_image_ids": 200     reject DescribeImages carrying more ids than this
    }

DescribeRegions is exempt from the "*" deny wildcard: it is what enumerates a
region in the first place, and an account whose region listing fails never
reaches any of its regions. Deny it explicitly to model that case.

GET /__stats returns the bookkeeping a test needs to assert on concurrency and
batching, and is answered without reference to the scenario or to SigV4:

    {"data_calls": 42, "peak_calls": 16, "peak_accounts": 4, "max_image_ids": 100}
"""

import json
import os
import re
import socketserver
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

SCENARIO = {}

# ── Cross-request bookkeeping ──────────────────────────────────────────────────
# A test asserts on these through /__stats: that the parallelism cap actually
# held, and that the AMI lookup was really split into batches.

STATS_LOCK = threading.Lock()
STATS = {
    "data_calls":    0,   # data calls answered, org-wide
    "peak_calls":    0,   # most data calls ever in flight at once
    "peak_accounts": 0,   # most distinct accounts ever in flight at once
    "max_image_ids": 0,   # largest ImageIds list seen on one DescribeImages
    "throttled":     0,   # attempts answered with a throttling error
}
IN_FLIGHT_CALLS = 0
IN_FLIGHT_ACCOUNTS = {}   # account id -> in-flight call count

THROTTLE_LOCK = threading.Lock()
THROTTLE_SEEN = {}        # "account/region/action" -> attempts seen so far


# ── Scenario helpers ───────────────────────────────────────────────────────────

def pad_id(prefix, i):
    """Ids are built by zero-padding the index as a string; arithmetic on
    17-digit values silently degrades to a float in some JSON encoders."""
    return f"{prefix}{str(i).zfill(17)}"


def tag_pad():
    n = int(SCENARIO.get("tag_pad", 0) or 0)
    return "x" * n if n > 0 else ""


def denied(account, region, action):
    actions = SCENARIO.get("deny", {}).get(f"{account}/{region}", [])
    if action in actions:
        return True
    # "*" denies every call the region serves. DescribeRegions is exempt so a
    # region can be unreachable without making the whole account unreachable.
    return "*" in actions and action != "DescribeRegions"


def corrupted(region, action):
    return action in SCENARIO.get("corrupt", {}).get(region, [])


def counts():
    return (
        int(SCENARIO.get("volumes", 0)),
        int(SCENARIO.get("instances", 0)),
        int(SCENARIO.get("snapshots", 0)),
        int(SCENARIO.get("ami_count", 3)),
    )


def page_bounds(params, total):
    """(start, end, next_token) for a result set, honouring the client's NextToken.

    The token is just the next offset rendered as a string — opaque to the
    client, which is all AWS promises about it.
    """
    size = int(SCENARIO.get("page_size", 0) or 0)
    try:
        start = int(params.get("NextToken") or 0)
    except ValueError:
        start = 0
    start = max(0, min(start, total))
    if size <= 0:
        return start, total, None
    end = min(start + size, total)
    return start, end, (str(end) if end < total else None)


# ── XML helpers ────────────────────────────────────────────────────────────────

def esc(v):
    return str(v).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def tags_xml(pairs):
    items = "".join(
        f"<item><key>{esc(k)}</key><value>{esc(v)}</value></item>" for k, v in pairs
    )
    return f"<tagSet>{items}</tagSet>"


def next_token_xml(token):
    return f"<nextToken>{esc(token)}</nextToken>" if token else ""


EC2_NS = "http://ec2.amazonaws.com/doc/2016-11-15/"
STS_NS = "https://sts.amazonaws.com/doc/2011-06-15/"


def ec2_error(code, message):
    return (
        '<?xml version="1.0"?><Response><Errors><Error>'
        f"<Code>{esc(code)}</Code><Message>{esc(message)}</Message>"
        "</Error></Errors><RequestID>req-mock</RequestID></Response>"
    )


# ── EC2 operations ─────────────────────────────────────────────────────────────

def describe_regions():
    items = "".join(
        f"<item><regionName>{esc(r)}</regionName>"
        f"<regionEndpoint>ec2.{esc(r)}.amazonaws.com</regionEndpoint></item>"
        for r in SCENARIO.get("regions", [])
    )
    return (
        f'<DescribeRegionsResponse xmlns="{EC2_NS}"><requestId>req-mock</requestId>'
        f"<regionInfo>{items}</regionInfo></DescribeRegionsResponse>"
    )


def describe_volumes(region, params):
    n, _, _, _ = counts()
    start, end, token = page_bounds(params, n)
    pad = tag_pad()
    items = []
    for i in range(start, end):
        items.append(
            "<item>"
            f"<volumeId>{pad_id('vol-', i)}</volumeId>"
            f"<size>{100 + (i % 900)}</size>"
            "<volumeType>gp3</volumeType><status>in-use</status>"
            "<encrypted>true</encrypted><iops>3000</iops><throughput>125</throughput>"
            f"<availabilityZone>{esc(region)}a</availabilityZone>"
            f"<snapshotId>{pad_id('snap-', i)}</snapshotId>"
            "<createTime>2026-01-01T00:00:00.000Z</createTime>"
            "<attachmentSet><item>"
            f"<volumeId>{pad_id('vol-', i)}</volumeId>"
            f"<instanceId>{pad_id('i-', i)}</instanceId>"
            "<device>/dev/xvda</device><status>attached</status>"
            "</item></attachmentSet>"
            + tags_xml([("Name", f"volume-{i}{pad}"),
                        ("Environment", f"env-{i % 7}{pad}")])
            + "</item>"
        )
    return (
        f'<DescribeVolumesResponse xmlns="{EC2_NS}"><requestId>req-mock</requestId>'
        f"<volumeSet>{''.join(items)}</volumeSet>{next_token_xml(token)}"
        "</DescribeVolumesResponse>"
    )


def describe_instances(region, account, params):
    _, n, _, amis = counts()
    start, end, token = page_bounds(params, n)
    pad = tag_pad()
    items = []
    for i in range(start, end):
        # One instance per reservation, matching how EC2 reports standalone
        # launches. Instances cycle through ami_count distinct AMIs so a case
        # can dial AMI cardinality independently of the instance count.
        items.append(
            "<item>"
            f"<reservationId>r-{i}</reservationId><ownerId>{esc(account)}</ownerId>"
            "<instancesSet><item>"
            f"<instanceId>{pad_id('i-', i)}</instanceId>"
            f"<imageId>{pad_id('ami-', i % amis)}</imageId>"
            "<instanceState><code>16</code><name>running</name></instanceState>"
            "<instanceType>m5.large</instanceType><hypervisor>xen</hypervisor>"
            "<platformDetails>Linux/UNIX</platformDetails>"
            "<architecture>x86_64</architecture><rootDeviceName>/dev/xvda</rootDeviceName>"
            f"<placement><availabilityZone>{esc(region)}a</availabilityZone></placement>"
            + tags_xml([("Name", f"instance-{i}{pad}"),
                        ("Environment", f"env-{i % 7}{pad}")])
            + "</item></instancesSet></item>"
        )
    return (
        f'<DescribeInstancesResponse xmlns="{EC2_NS}"><requestId>req-mock</requestId>'
        f"<reservationSet>{''.join(items)}</reservationSet>{next_token_xml(token)}"
        "</DescribeInstancesResponse>"
    )


def describe_snapshots(params):
    _, _, n, _ = counts()
    start, end, token = page_bounds(params, n)
    pad = tag_pad()
    items = []
    for i in range(start, end):
        items.append(
            "<item>"
            f"<snapshotId>{pad_id('snap-', i)}</snapshotId>"
            f"<volumeId>{pad_id('vol-', i)}</volumeId>"
            f"<volumeSize>{100 + (i % 900)}</volumeSize>"
            "<startTime>2026-01-01T00:00:00.000Z</startTime>"
            "<status>completed</status><encrypted>true</encrypted>"
            + tags_xml([("Name", f"snapshot-{i}{pad}")])
            + "</item>"
        )
    return (
        f'<DescribeSnapshotsResponse xmlns="{EC2_NS}"><requestId>req-mock</requestId>'
        f"<snapshotSet>{''.join(items)}</snapshotSet>{next_token_xml(token)}"
        "</DescribeSnapshotsResponse>"
    )


def describe_images(image_ids):
    items = []
    for image_id in image_ids:
        items.append(
            "<item>"
            f"<imageId>{esc(image_id)}</imageId>"
            f"<name>image-{esc(image_id)}</name>"
            f"<description>mock image {esc(image_id)}</description>"
            "<architecture>x86_64</architecture>"
            "<imageState>available</imageState><imageType>machine</imageType>"
            "</item>"
        )
    return (
        f'<DescribeImagesResponse xmlns="{EC2_NS}"><requestId>req-mock</requestId>'
        f"<imagesSet>{''.join(items)}</imagesSet></DescribeImagesResponse>"
    )


# A response served with a 200 and a matching Content-Length, but whose body
# stops mid-element — a truncated read, a proxy that cut the connection, a short
# write upstream. Every client parses XML strictly, so all three must see this
# as a failed call rather than as an empty result. (DT-11095)
TRUNCATED_BODY = (
    f'<?xml version="1.0"?><DescribeVolumesResponse xmlns="{EC2_NS}">'
    "<requestId>req-mock</requestId><volumeSet><item>"
    "<volumeId>vol-00000000000000001</volumeId><size>100</size><tagSet><item><ke"
)


# ── STS ────────────────────────────────────────────────────────────────────────

def get_caller_identity():
    acct = SCENARIO.get("caller_account", "000000000000")
    return (
        f'<GetCallerIdentityResponse xmlns="{STS_NS}"><GetCallerIdentityResult>'
        f"<Arn>arn:aws:iam::{esc(acct)}:user/mock</Arn>"
        "<UserId>AIDAMOCK</UserId>"
        f"<Account>{esc(acct)}</Account>"
        "</GetCallerIdentityResult>"
        "<ResponseMetadata><RequestId>req-mock</RequestId></ResponseMetadata>"
        "</GetCallerIdentityResponse>"
    )


def assume_role(role_arn):
    target = role_arn.split("::")[1].split(":")[0]
    return (
        f'<AssumeRoleResponse xmlns="{STS_NS}"><AssumeRoleResult><Credentials>'
        f"<AccessKeyId>AKIAMOCK{esc(target)}</AccessKeyId>"
        "<SecretAccessKey>mock-secret</SecretAccessKey>"
        "<SessionToken>mock-token</SessionToken>"
        "<Expiration>2099-01-01T00:00:00Z</Expiration>"
        "</Credentials><AssumedRoleUser>"
        f"<Arn>arn:aws:sts::{esc(target)}:assumed-role/mock/DatafyDiscovery</Arn>"
        "<AssumedRoleId>AROAMOCK:DatafyDiscovery</AssumedRoleId>"
        "</AssumedRoleUser></AssumeRoleResult>"
        "<ResponseMetadata><RequestId>req-mock</RequestId></ResponseMetadata>"
        "</AssumeRoleResponse>"
    )


# ── Data-call behaviours ───────────────────────────────────────────────────────
# The inventory calls are the ones worth instrumenting: they are what runs
# concurrently, what a long scan outlives, and what returns bulk payloads.

DATA_ACTIONS = {
    "DescribeVolumes", "DescribeInstances", "DescribeSnapshots", "DescribeImages",
    "GetLifecyclePolicies", "ListBackupPlans",
}


class DataCall:
    """Registers a data call as in flight for as long as it is being answered,
    so /__stats can report the peak the implementation actually reached."""

    def __init__(self, account):
        self.account = account

    def __enter__(self):
        global IN_FLIGHT_CALLS
        with STATS_LOCK:
            IN_FLIGHT_CALLS += 1
            IN_FLIGHT_ACCOUNTS[self.account] = IN_FLIGHT_ACCOUNTS.get(self.account, 0) + 1
            STATS["data_calls"] += 1
            STATS["peak_calls"] = max(STATS["peak_calls"], IN_FLIGHT_CALLS)
            STATS["peak_accounts"] = max(STATS["peak_accounts"], len(IN_FLIGHT_ACCOUNTS))
        return self

    def __exit__(self, *_exc):
        global IN_FLIGHT_CALLS
        with STATS_LOCK:
            IN_FLIGHT_CALLS -= 1
            remaining = IN_FLIGHT_ACCOUNTS.get(self.account, 1) - 1
            if remaining <= 0:
                IN_FLIGHT_ACCOUNTS.pop(self.account, None)
            else:
                IN_FLIGHT_ACCOUNTS[self.account] = remaining
        return False


def apply_delay(account):
    """Hold a call open, so a test can act while the scan is genuinely in flight."""
    seconds = SCENARIO.get("delay_seconds")
    if not seconds:
        return
    only = SCENARIO.get("delay_accounts") or []
    if only and account not in only:
        return
    time.sleep(float(seconds))


def throttled(account, region, action):
    """Whether this attempt should be answered with a throttling error.

    A 900-account scan makes tens of thousands of calls and AWS will push back.
    Every client retries throttling with exponential backoff, so what matters is
    whether the tool rides the burst out — hence the per-attempt counter: the
    first N attempts of a given account/region/action fail, and the attempt
    after that succeeds, which only happens if the client actually retried.
    """
    forever = SCENARIO.get("throttle_forever") or []
    limit = int((SCENARIO.get("throttle") or {}).get(action, 0) or 0)
    if action not in forever and limit <= 0:
        return False

    if action not in forever:
        key = f"{account}/{region}/{action}"
        with THROTTLE_LOCK:
            seen = THROTTLE_SEEN.get(key, 0) + 1
            THROTTLE_SEEN[key] = seen
        if seen > limit:
            return False

    with STATS_LOCK:
        STATS["throttled"] += 1
    return True


def session_expired():
    """Assumed credentials last an hour; a 900-account scan can outlive that,
    after which every remaining call fails for the rest of the run."""
    limit = SCENARIO.get("expire_after")
    if not limit:
        return False
    with STATS_LOCK:
        return STATS["data_calls"] > int(limit)


# ── Request handling ───────────────────────────────────────────────────────────

CRED_RE = re.compile(r"Credential=([^/]+)/[^/]+/([^/]+)/([^/]+)/")

# The JSON-protocol services, and the action each of their calls represents.
# They are plain GETs, so the action cannot be read off the request body.
JSON_SERVICES = {
    "dlm":    ("GetLifecyclePolicies", {"Policies": []}),
    "backup": ("ListBackupPlans",      {"BackupPlansList": []}),
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass  # keep the harness output readable

    # -- helpers ---------------------------------------------------------------

    def _scope(self):
        """(access_key, region, service) from the SigV4 credential scope."""
        m = CRED_RE.search(self.headers.get("Authorization", "") or "")
        return m.groups() if m else ("", "us-east-1", "")

    def _account(self, access_key):
        if access_key.startswith("AKIAMOCK"):
            return access_key[len("AKIAMOCK"):]
        return SCENARIO.get("caller_account", "000000000000")

    def _send(self, body, status=200, content_type="text/xml", headers=()):
        raw = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("x-amzn-RequestId", "req-mock")
        for key, value in headers:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(raw)

    def _error(self, code, message, status=403, service="ec2"):
        """An error in the shape the service's own protocol uses — a client only
        surfaces the error code if it is where that protocol expects it."""
        if service in JSON_SERVICES:
            self._send(json.dumps({"__type": code, "message": message}),
                       status=status, content_type="application/x-amz-json-1.1",
                       headers=[("x-amzn-ErrorType", f"{code}:")])
        elif service == "sts":
            self._send(
                f'<ErrorResponse xmlns="{STS_NS}"><Error><Type>Sender</Type>'
                f"<Code>{esc(code)}</Code><Message>{esc(message)}</Message></Error>"
                "<RequestId>req-mock</RequestId></ErrorResponse>",
                status=status)
        else:
            self._send(ec2_error(code, message), status=status)

    def _guard_data_call(self, account, region, action, service):
        """Shared pre-flight for every inventory call: denial, expiry, damage.

        Returns True when the call has already been answered.
        """
        if denied(account, region, action):
            self._error("UnauthorizedOperation", f"mock denial for {action}",
                        service=service)
            return True
        if throttled(account, region, action):
            # EC2 says RequestLimitExceeded with a 503; the JSON-protocol
            # services say ThrottlingException with a 400. Both codes are in
            # every client's retryable set, which is the point — a client that
            # does not retry them fails this call outright.
            if service in JSON_SERVICES:
                self._error("ThrottlingException", "Rate exceeded",
                            status=400, service=service)
            else:
                self._error("RequestLimitExceeded", "Request limit exceeded",
                            status=503, service=service)
            return True
        if session_expired():
            self._error("ExpiredToken",
                        "The security token included in the request is expired",
                        service=service)
            return True
        if corrupted(region, action):
            self._send(TRUNCATED_BODY)
            return True
        return False

    # -- verbs -----------------------------------------------------------------

    def do_GET(self):
        if self.path.startswith("/__stats"):
            with STATS_LOCK:
                snapshot = dict(STATS)
            self._send(json.dumps(snapshot), content_type="application/json")
            return

        access_key, region, service = self._scope()
        account = self._account(access_key)

        if service not in JSON_SERVICES:
            self._error("InvalidAction", self.path, status=400)
            return

        action, empty_response = JSON_SERVICES[service]
        with DataCall(account):
            apply_delay(account)
            if self._guard_data_call(account, region, action, service):
                return
            self._send(json.dumps(empty_response),
                       content_type="application/x-amz-json-1.1")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        access_key, region, service = self._scope()
        account = self._account(access_key)

        # Organizations uses JSON-1.1 with the operation in a header.
        target = self.headers.get("X-Amz-Target", "")
        if "ListAccounts" in target or service == "organizations":
            self._send(json.dumps({
                "Accounts": [
                    {"Id": a, "Status": "ACTIVE", "Name": f"account-{a}",
                     "Email": f"{a}@example.invalid",
                     "Arn": f"arn:aws:organizations::{a}:account/o-mock/{a}"}
                    for a in SCENARIO.get("accounts", [])
                ]
            }), content_type="application/x-amz-json-1.1")
            return

        params = {k: v[0] for k, v in parse_qs(body).items()}
        action = params.get("Action", "")

        if service == "sts" or action in ("GetCallerIdentity", "AssumeRole"):
            if action == "GetCallerIdentity":
                self._send(get_caller_identity())
            elif action == "AssumeRole":
                arn = params.get("RoleArn", "")
                target_account = arn.split("::")[1].split(":")[0] if "::" in arn else ""
                if target_account in SCENARIO.get("deny_assume", []):
                    self._error("AccessDenied", "mock denial", service="sts")
                else:
                    self._send(assume_role(arn))
            else:
                self._error("InvalidAction", action, status=400)
            return

        # DescribeRegions is not a data call: it is never delayed, throttled or
        # expired, because it is what makes a region visible in the first place.
        if action == "DescribeRegions":
            if denied(account, region, action):
                self._error("UnauthorizedOperation", "mock denial for DescribeRegions")
            else:
                self._send(describe_regions())
            return

        if action not in DATA_ACTIONS:
            self._error("InvalidAction", action or self.path, status=400)
            return

        with DataCall(account):
            apply_delay(account)
            if self._guard_data_call(account, region, action, service or "ec2"):
                return

            if action == "DescribeVolumes":
                self._send(describe_volumes(region, params))
            elif action == "DescribeInstances":
                self._send(describe_instances(region, account, params))
            elif action == "DescribeSnapshots":
                self._send(describe_snapshots(params))
            elif action == "DescribeImages":
                self._describe_images(params)

    def _describe_images(self, params):
        ids = [v for k, v in sorted(params.items()) if k.startswith("ImageId.") and v]

        with STATS_LOCK:
            STATS["max_image_ids"] = max(STATS["max_image_ids"], len(ids))

        # The real API rejects an unbounded id list. Enforcing that here is what
        # makes AMI batching testable at all — an implementation that sends every
        # id in one call gets an error, not a convenient answer. (DT-11095)
        cap = int(SCENARIO.get("max_image_ids", 0) or 0)
        if cap and len(ids) > cap:
            self._error("InvalidParameterValue",
                        f"The maximum number of image IDs that may be specified is {cap}",
                        status=400)
            return

        self._send(describe_images(ids))


class Server(ThreadingHTTPServer):
    """HTTPServer.server_bind() calls socket.getfqdn() to fill in server_name,
    which is a reverse-DNS lookup that blocks for seconds — or never returns —
    on a machine with no reverse record for loopback. Nothing here uses
    server_name, so bind without it."""

    daemon_threads = True
    # A scan opens one connection per concurrent call; the default backlog of 5
    # turns a burst into connection-refused errors that look like AWS failures.
    request_queue_size = 256

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


def main():
    global SCENARIO
    scenario_path = os.environ.get("FAKE_AWS_SCENARIO")
    if not scenario_path:
        sys.exit("FAKE_AWS_SCENARIO must name a scenario JSON file")
    with open(scenario_path) as fh:
        SCENARIO = json.load(fh)

    port = int(os.environ.get("FAKE_AWS_PORT", "0"))
    server = Server(("127.0.0.1", port), Handler)
    # Announce the bound port so the harness can let the OS choose a free one.
    print(server.server_address[1], flush=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
