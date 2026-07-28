#!/usr/bin/env python3
"""
A fake AWS endpoint for the cross-implementation parity harness.

The three discovery implementations talk to AWS through three different clients
— the AWS CLI, boto3, and aws-sdk-go-v2 — so mocking at the client level (as
bash/test/lib/mock_aws.sh does) can only ever test one of them. All three
honour AWS_ENDPOINT_URL, so pointing them at a single server here exercises the
real clients, the real signing and the real pagination, and lets the harness
diff what each implementation actually produces.

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
      "deny_assume":    ["222222222222"],
      "deny":           {"111111111111/eu-west-1": ["DescribeVolumes"]}
    }
"""

import json
import os
import re
import socketserver
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

SCENARIO = {}


# ── Scenario helpers ───────────────────────────────────────────────────────────

def pad_id(prefix, i):
    """Ids are built by zero-padding the index as a string; arithmetic on
    17-digit values silently degrades to a float in some JSON encoders."""
    return f"{prefix}{str(i).zfill(17)}"


def denied(account, region, action):
    return action in SCENARIO.get("deny", {}).get(f"{account}/{region}", [])


def counts():
    return (
        int(SCENARIO.get("volumes", 0)),
        int(SCENARIO.get("instances", 0)),
        int(SCENARIO.get("snapshots", 0)),
        int(SCENARIO.get("ami_count", 3)),
    )


# ── XML helpers ────────────────────────────────────────────────────────────────

def esc(v):
    return str(v).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def tags_xml(pairs):
    items = "".join(
        f"<item><key>{esc(k)}</key><value>{esc(v)}</value></item>" for k, v in pairs
    )
    return f"<tagSet>{items}</tagSet>"


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


def describe_volumes(region):
    n, _, _, _ = counts()
    items = []
    for i in range(n):
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
            + tags_xml([("Name", f"volume-{i}"), ("Environment", f"env-{i % 7}")])
            + "</item>"
        )
    return (
        f'<DescribeVolumesResponse xmlns="{EC2_NS}"><requestId>req-mock</requestId>'
        f"<volumeSet>{''.join(items)}</volumeSet></DescribeVolumesResponse>"
    )


def describe_instances(region, account):
    _, n, _, amis = counts()
    items = []
    for i in range(n):
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
            + tags_xml([("Name", f"instance-{i}"), ("Environment", f"env-{i % 7}")])
            + "</item></instancesSet></item>"
        )
    return (
        f'<DescribeInstancesResponse xmlns="{EC2_NS}"><requestId>req-mock</requestId>'
        f"<reservationSet>{''.join(items)}</reservationSet></DescribeInstancesResponse>"
    )


def describe_snapshots():
    _, _, n, _ = counts()
    items = []
    for i in range(n):
        items.append(
            "<item>"
            f"<snapshotId>{pad_id('snap-', i)}</snapshotId>"
            f"<volumeId>{pad_id('vol-', i)}</volumeId>"
            f"<volumeSize>{100 + (i % 900)}</volumeSize>"
            "<startTime>2026-01-01T00:00:00.000Z</startTime>"
            "<status>completed</status><encrypted>true</encrypted>"
            + tags_xml([("Name", f"snapshot-{i}")])
            + "</item>"
        )
    return (
        f'<DescribeSnapshotsResponse xmlns="{EC2_NS}"><requestId>req-mock</requestId>'
        f"<snapshotSet>{''.join(items)}</snapshotSet></DescribeSnapshotsResponse>"
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


# ── Request handling ───────────────────────────────────────────────────────────

CRED_RE = re.compile(r"Credential=([^/]+)/[^/]+/([^/]+)/([^/]+)/")


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

    def _send(self, body, status=200, content_type="text/xml"):
        raw = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("x-amzn-RequestId", "req-mock")
        self.end_headers()
        self.wfile.write(raw)

    def _deny(self, action, service="ec2"):
        if service == "sts":
            body = (
                f'<ErrorResponse xmlns="{STS_NS}"><Error><Type>Sender</Type>'
                "<Code>AccessDenied</Code><Message>mock denial</Message></Error>"
                "<RequestId>req-mock</RequestId></ErrorResponse>"
            )
        else:
            body = ec2_error("UnauthorizedOperation", f"mock denial for {action}")
        self._send(body, status=403)

    # -- verbs -----------------------------------------------------------------

    def do_GET(self):
        _, _, service = self._scope()
        if service == "dlm":
            self._send(json.dumps({"Policies": []}), content_type="application/json")
        elif service == "backup":
            self._send(json.dumps({"BackupPlansList": []}), content_type="application/json")
        else:
            self._send(ec2_error("InvalidAction", self.path), status=400)

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
                    self._deny("AssumeRole", service="sts")
                else:
                    self._send(assume_role(arn))
            else:
                self._send(ec2_error("InvalidAction", action), status=400)
            return

        if denied(account, region, action):
            self._deny(action)
            return

        if action == "DescribeRegions":
            self._send(describe_regions())
        elif action == "DescribeVolumes":
            self._send(describe_volumes(region))
        elif action == "DescribeInstances":
            self._send(describe_instances(region, account))
        elif action == "DescribeSnapshots":
            self._send(describe_snapshots())
        elif action == "DescribeImages":
            ids = [v for k, v in sorted(params.items())
                   if k.startswith("ImageId.") and v]
            self._send(describe_images(ids))
        else:
            self._send(ec2_error("InvalidAction", action or self.path), status=400)


class Server(ThreadingHTTPServer):
    """HTTPServer.server_bind() calls socket.getfqdn() to fill in server_name,
    which is a reverse-DNS lookup that blocks for seconds — or never returns —
    on a machine with no reverse record for loopback. Nothing here uses
    server_name, so bind without it."""

    daemon_threads = True

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
