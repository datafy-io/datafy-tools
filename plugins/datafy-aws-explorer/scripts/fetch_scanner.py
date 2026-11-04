#!/usr/bin/env python3
"""Download the pinned Datafy discovery scanner and verify its SHA-256.

The release tag and every asset checksum live in scanner.lock.json, so what runs is
exactly what Datafy published. Contacts github.com only; sends nothing about you.

  fetch_scanner.py [--dest DIR] [--prefer python|binary]
Prints the path of the verified scanner on stdout.
"""
import argparse
import hashlib
import json
import os
import platform
import shutil
import ssl
import stat
import subprocess
import sys
import urllib.error
import urllib.request

from common import log

LOCK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scanner.lock.json")


def load_lock(path=LOCK):
    with open(path) as f:
        return json.load(f)


def binary_asset_name():
    sysname = {"Darwin": "darwin", "Linux": "linux", "Windows": "windows"}.get(platform.system())
    arch = {"x86_64": "amd64", "AMD64": "amd64", "arm64": "arm64", "aarch64": "arm64"}.get(platform.machine())
    if not sysname or not arch:
        return None
    return "discovery-aws-%s-%s%s" % (sysname, arch, ".exe" if sysname == "windows" else "")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _is_cert_problem(e):
    reason = getattr(e, "reason", e)
    return isinstance(reason, ssl.SSLCertVerificationError) or "CERTIFICATE_VERIFY_FAILED" in str(e)


def _download(url, tmp, opener):
    with opener(url) as r, open(tmp, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)


def fetch(asset, dest, lock, opener=urllib.request.urlopen):
    expected = lock["assets"].get(asset)
    if not expected:
        raise SystemExit("asset %r is not in scanner.lock.json" % asset)
    os.makedirs(dest, exist_ok=True)
    out = os.path.join(dest, asset)
    if os.path.exists(out) and sha256_file(out) == expected:
        return out
    url = lock["base_url"] + asset
    log("downloading %s" % url)
    tmp = out + ".part"
    try:
        _download(url, tmp, opener)
    except (urllib.error.URLError, ssl.SSLError) as e:
        # Some Python installs (notably python.org builds on macOS) ship no root certificates.
        # Verification is never disabled; the system curl uses the OS trust store instead.
        # The pinned SHA-256 below still decides whether the file is trusted.
        if not _is_cert_problem(e) or not shutil.which("curl"):
            raise SystemExit("could not download %s: %s" % (url, e))
        log("python has no CA certificates; retrying with the system curl")
        r = subprocess.run(["curl", "-fsSL", "--proto", "=https", "-o", tmp, url])
        if r.returncode != 0:
            raise SystemExit("could not download %s (curl exit %d)" % (url, r.returncode))
    got = sha256_file(tmp)
    if got != expected:
        os.remove(tmp)
        raise SystemExit("checksum mismatch for %s: expected %s, got %s. Refusing to run it." % (asset, expected, got))
    os.replace(tmp, out)
    if not asset.endswith(".py"):
        os.chmod(out, os.stat(out).st_mode | stat.S_IXUSR)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dest", default=os.path.join(os.path.expanduser("~"), ".cache", "datafy-aws-explorer"))
    ap.add_argument("--prefer", choices=["python", "binary"], default="binary")
    a = ap.parse_args(argv)
    lock = load_lock()
    binary = binary_asset_name()
    use_binary = a.prefer == "binary" and binary in lock["assets"]
    path = fetch(binary if use_binary else "discovery-aws.py", os.path.join(a.dest, lock["release"]), lock)
    print(path)


if __name__ == "__main__":
    main()
