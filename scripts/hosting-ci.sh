#!/usr/bin/env bash
# ==============================================================================
# hosting-ci.sh — static gates for the hosting stack (iteration 29 doctrine).
#
# Every defect that reached a live host on 2026-11-23 is a gate here:
#   defect 1  unparseable cloud-init snippet      -> gate 3 (YAML lint)
#   defect 4  duplicate YAML key                  -> gate 3 (key-duplicates)
#   defect 7  Jinja template that never rendered  -> gate 4 (jinja parse)
#   defect 12 cAdvisor numa flag / healthcheck    -> gate 6 (image tags exist)
#   defect 15 provisioner without its templates   -> gate 5 (tree presence)
#   defect 16 image pins naming nonexistent tags  -> gate 6 (registry truth)
#   defect 17 userns chown / data-uid present     -> gate 5 (data-uid file)
#   broken shell in ops scripts                   -> gate 2 (bash -n + shellcheck)
#
# Usage: scripts/hosting-ci.sh [--offline]   (offline skips registry checks)
# Exit: 0 = all gates pass; nonzero = the review/CI must stop.
# ==============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OFFLINE=0
[ "${1:-}" = "--offline" ] && OFFLINE=1

PASS=0; FAIL=0
gate() { # gate <name> <cmd...>
    local name="$1"; shift
    if "$@" >/tmp/hosting-ci.$$ 2>&1; then
        echo "[PASS] $name"; PASS=$((PASS+1))
    else
        echo "[FAIL] $name"; sed 's/^/       /' /tmp/hosting-ci.$$ | head -15; FAIL=$((FAIL+1))
    fi
    rm -f /tmp/hosting-ci.$$
}

echo "== hosting stack CI gates (root: $ROOT)"

# --- 1. ansible syntax -------------------------------------------------------
gate "ansible syntax-check (hosting_bootstrap)" bash -c "
    cd '$ROOT/ansible' && ansible-playbook -i inventory/hosts.yml \
        --syntax-check playbooks/hosting_bootstrap.yml"

# --- 2. shell hygiene (ops scripts) ------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    gate "shellcheck (ops/*.sh)" \
        shellcheck -S warning -x "$ROOT"/ops/*.sh "$ROOT"/ops/hosting/*.sh
else
    gate "bash -n (ops/*.sh)" bash -c \
        'for f in '"$ROOT"'/ops/*.sh '"$ROOT"'/ops/hosting/*.sh; do bash -n "$f"; done'
fi

# --- 3. YAML validity + duplicate keys (defect 4) ----------------------------
gate "yamllint (inventory, group/host vars, roles)" bash -c "
    yamllint -d '{rules: {key-duplicates: {error: true}, line-length: disable,
                          truthy: disable, comments: disable,
                          indentation: disable, new-lines: disable,
                          document-start: disable}}' \
        '$ROOT/ansible/inventory/' '$ROOT/ansible/roles/hosting_docker_host/' \
        '$ROOT/ansible/roles/hosting_edge/' \
        '$ROOT/ops/hosting/' 2>/dev/null || yamllint -d relaxed \
        '$ROOT/ansible/inventory/' '$ROOT/ansible/roles/hosting_docker_host/' \
        '$ROOT/ansible/roles/hosting_edge/' '$ROOT/ops/hosting/'"

# --- 3b. cloud-init snippets parse + carry BOTH deploy keys (defect 1) -------
gate "cloud-init snippets parse + deploy key present" python3 -c "
import yaml, glob, sys
bad = []
for f in glob.glob('$ROOT/ops/hosting/docker0*-user-data.yaml'):
    try:
        d = yaml.safe_load(open(f))
        keys = d['users'][0]['ssh_authorized_keys']
        if not any('terraform-provider@hosting01' in k for k in keys):
            bad.append(f + ': deploy key missing')
        if not any('wyatt@cachyos' in k for k in keys):
            bad.append(f + ': operator key missing')
    except Exception as e:
        bad.append(f + ': ' + str(e))
sys.exit('\n'.join(bad) if bad else 0)"

# --- 4. every role template renders as Jinja (defects 7, 12) -----------------
gate "jinja2 parses all hosting templates" python3 -c "
import glob, jinja2, sys
bad = []
for f in glob.glob('$ROOT/ansible/roles/*/templates/*.j2'):
    try:
        jinja2.Environment().parse(open(f).read())
    except jinja2.exceptions.TemplateSyntaxError as e:
        bad.append(f + f': {e}')
sys.exit('\n'.join(bad) if bad else 0)"

# --- 5. provisioner integrity (defects 15, 17) -------------------------------
gate "tenant templates present + data-uid declared" bash -c '
    for svc in '"$ROOT"'/ops/tenants/templates/*/; do
        name=$(basename "$svc")
        [ -f "$svc/docker-compose.yml" ] || { echo "$name: no compose"; exit 1; }
        [ -f "$svc/env.template" ] || { echo "$name: no env.template"; exit 1; }
    done
    # any template binding a host dir under userns must declare its uid
    for d in '"$ROOT"'/ops/tenants/templates/*/; do
        if grep -qE "^\s*- .*/data" "$d/docker-compose.yml" 2>/dev/null && \
           [ ! -f "$d/data-uid" ]; then
            echo "$(basename $d): bind-mounted /data without data-uid (userns EACCES)"
            exit 1
        fi
    done'

# --- 6. image pins name REAL registry tags (defect 16) -----------------------
if [ "$OFFLINE" = 0 ]; then
    gate "image pins resolve in their registries" \
        python3 "$ROOT/scripts/check-image-pins.py"
else
    echo "[SKIP] image pins (offline)"
fi

echo "== summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
