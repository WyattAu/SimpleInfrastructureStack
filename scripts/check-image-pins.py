#!/usr/bin/env python3
"""Verify every tenant template's image pins exist in their registry.

Defect-16 gate (iteration 29): pins that name tags the registry never
had broke every tenant pull.

Registry access notes (learned the hard way, 2026-11-24):
- ghcr rate-limits anonymous traffic to nothing — use docker creds from
  ~/.docker/config.json (set by `docker login ghcr.io`) when present.
- ONE token per repo: batched multi-scope token requests silently drop
  scopes past a cap, so later repos 404 with a "valid" token.
- 404 can ALSO be a transient rate-limit artifact: retry once before
  believing a pin is missing.

Templates with a DRAFT marker file are checked but their misses are
reported as PENDING (non-fatal) — they are waiting on EIR publishes.
"""
import base64
import glob
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

ROOT = os.environ.get(
    "HOSTING_CI_ROOT",
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
)
UA = {"User-Agent": "hosting-ci/1.0 (SIS hosting-ci; contact: wyatt@wyattau.com)"}
RETRIES = 2


def ghcr_creds():
    try:
        cfg = json.load(open(os.path.expanduser("~/.docker/config.json")))
        auth = cfg.get("auths", {}).get("ghcr.io", {}).get("auth")
        if auth:
            user, _, pw = base64.b64decode(auth).decode().partition(":")
            return user, pw
    except Exception:
        pass
    return None


CRED = ghcr_creds()


def ghcr_token(repo):
    # per-repo tokens with real backoff: ghcr rate-limits bursts of token
    # requests hard (403), and a 403 here masquerades as a missing tag
    # downstream (iteration 29: the whole gate flapped on this).
    url = f"https://ghcr.io/token?service=ghcr.io&scope=repository:{repo}:pull"
    headers = dict(UA)
    if CRED:
        headers["Authorization"] = (
            "Basic " + __import__("base64").b64encode(
                f"{CRED[0]}:{CRED[1]}".encode()).decode()
        )
    last = None
    for attempt in range(1, 4):
        try:
            return json.load(urllib.request.urlopen(
                urllib.request.Request(url, headers=headers), timeout=30))["token"]
        except Exception as e:
            last = e
            time.sleep(10 * attempt)
    raise last


def tag_exists(repo, tag):
    token = ghcr_token(repo)
    req = urllib.request.Request(
        f"https://ghcr.io/v2/{repo}/manifests/{tag}",
        headers={
            "Authorization": "Bearer " + token,
            "User-Agent": UA["User-Agent"],
            "Accept": (
                "application/vnd.oci.image.index.v1+json, "
                "application/vnd.oci.image.manifest.v1+json, "
                "application/vnd.docker.distribution.manifest.list.v2+json, "
                "application/vnd.docker.distribution.manifest.v2+json"
            ),
        },
    )
    for attempt in range(1, RETRIES + 2):
        try:
            urllib.request.urlopen(req, timeout=30)
            return True, None
        except urllib.error.HTTPError as e:
            # 404 twice (8s apart) before believing a pin is missing —
            # ghcr serves transient 404s under rate pressure
            if e.code == 404 and attempt <= RETRIES:
                time.sleep(8)
                continue
            return False, f"HTTP {e.code}"
        except Exception as e:
            if attempt <= RETRIES:
                time.sleep(8)
                continue
            return False, str(e)
    return False, "unreachable"


fatal = []
pending = []
ok = 0

for f in sorted(glob.glob(os.path.join(ROOT, "ops/tenants/templates/*/versions.env"))):
    svc = os.path.basename(os.path.dirname(f))
    draft = os.path.exists(os.path.join(os.path.dirname(f), "DRAFT"))
    compose = open(os.path.join(os.path.dirname(f), "docker-compose.yml")).read()
    for line in open(f):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, tag = line.split("=", 1)
        if not re.match(r"^\w+_VERSION$", key) or tag.startswith("$"):
            continue
        imgs = re.findall(r"image:\s*(\S+)", compose)
        hit = [i for i in imgs if "${" + key + "}" in i]
        if not hit:
            continue
        image = hit[0].split("${")[0].rstrip("/:").rstrip(":")
        # repo = everything after the registry host when a host is
        # present (ghcr.io/wyattau/evergreenimageregistry/postgres is
        # FOUR segments — split[-2:] silently dropped the owner and
        # queried a nonexistent repo, 404-ing every EIR pin (iteration
        # 29 gate bug found by the gate's own investigation).
        parts = image.split("/")
        repo = "/".join(parts[1:]) if (
            "." in parts[0] or ":" in parts[0] or parts[0] == "localhost"
        ) else "/".join(parts[-2:])
        exists, err = tag_exists(repo, tag)
        if exists:
            ok += 1
            print(f"[OK] {svc}: {repo}:{tag}")
        elif draft:
            pending.append(f"[PENDING] {svc}: {repo}:{tag} -> {err} (DRAFT)")
        else:
            fatal.append(f"[FATAL] {svc}: {repo}:{tag} -> {err}")
        time.sleep(0.5)

print(f"pins: {ok} ok, {len(fatal)} fatal, {len(pending)} pending")
for m in pending:
    print(m)
for m in fatal:
    print(m)
sys.exit(1 if fatal else 0)
