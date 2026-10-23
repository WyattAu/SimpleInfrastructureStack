#!/bin/bash
# keycloak-realm-export.sh — capture the live Keycloak realm into git.
# Research loop iter 42. Runs on TrueNAS (docker access to iam-keycloak).
#
# The realm configuration has historically lived ONLY in Keycloak's
# database, built by hand through the admin UI - invisible to git, to
# the drift checks (iter 22), and to any realm re-bootstrap (staging,
# iter 36; Keycloak major upgrades). This script is the capture half of
# the drift doctrine: the LIVE system stays authoritative, git becomes
# its mirror, and UI changes get CAPTURED on the next run instead of
# diverging silently.
#
# The import direction (adorsys/keycloak-config-cli applying git ->
# realm) is deliberately NOT adopted yet: with one operator the UI is
# a legitimate write path, and an importer would revert it. Revisit at
# multi-realm / authbox rollout / staging bootstrap.
#
# Usage: keycloak-realm-export.sh [realm] [out-dir]
set -euo pipefail

REALM="${1:-company-realm}"
# Default home: the sis appdata tree — covered by the nightly restic
# sweep, and deliberately NOT the deploy checkout (an uncommitted file
# there would trip the iter-22 drift check; the mirror lives where
# backups live, not where force-sync lives).
OUT="${2:-/mnt/pool_HDD_x2/tank/datasources/sis/appdata/iam/realm-export}"
CONTAINER="${KEYCLOAK_CONTAINER:-iam-keycloak}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# kc.sh export opens its own connection to the same postgres database
# (MVCC: each read sees a consistent snapshot). Offline-export semantics
# without stopping the identity provider.
docker exec "$CONTAINER" /opt/keycloak/bin/kc.sh export \
    --dir "$TMP" --realm "$REALM" >/dev/null

mkdir -p "$OUT"
if [ ! -f "$TMP/$REALM-realm.json" ]; then
    echo "export did not produce $REALM-realm.json - inspect:" >&2
    ls -la "$TMP" >&2 || true
    exit 1
fi

# Strip volatile/instance-specific fields so the mirror diffs cleanly:
# internal UUIDs (regenerated per import), nothing user-visible.
python3 - "$TMP/$REALM-realm.json" "$OUT/$REALM-realm.json" <<'PY'
import json, sys

src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    realm = json.load(f)

realm.pop("id", None)
for client in realm.get("clients") or []:
    client.pop("id", None)
for scope_map in (realm.get("clientScopes") or []):
    scope_map.pop("id", None)
for role in ((realm.get("roles") or {}).get("realm") or []):
    role.pop("id", None)
for role in ((realm.get("roles") or {}).get("client") or {}).values():
    for r in role or []:
        r.pop("id", None)

with open(dst, "w") as f:
    json.dump(realm, f, indent=2, sort_keys=True)
    f.write("\n")
PY

echo "[$(date -Is)] realm '$REALM' mirrored to $OUT/$REALM-realm.json"
echo "NOTE: users are NOT exported (kc export writes <realm>-users-*.json"
echo "separately and user data is GDPR-personal - the retention table in"
echo "the hosting spec governs it, git does not store it)."
