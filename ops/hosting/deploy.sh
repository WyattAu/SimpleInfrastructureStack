#!/usr/bin/env bash
# ==============================================================================
# deploy.sh — one command from zero to serving (iteration 29, 2026-11-23).
#
#   ops/hosting/deploy.sh [--replace docker01|docker02] [--skip-build]
#
# The centralized, deterministic path. Everything tonight's bootstrap proved
# necessary lives in SOURCE artifacts (terraform/, ansible/, ops/); this
# wrapper is just their invocation order:
#
#   1. dashboard artifact build (cargo + bun)            [skippable]
#   2. cloud-init snippets -> node (ops/hosting/deploy-cloudinit.sh)
#   3. terraform apply  (--replace forces a VM rebuild from the template)
#   4. resolve mgmt IPs from the PVE guest agent -> generated inventory
#   5. ansible bootstrap (hosts: hosting)
#
# One key, no operator-agent dependency: HOSTING01_DEPLOY_KEY (default
# ~/.config/opencode/keys/hosting01-deploy-ed25519) is authorized on the
# node (root) and every docker0X guest (wyatt).
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NODE="${HOSTING01_NODE:-192.168.0.120}"
KEY="${HOSTING01_DEPLOY_KEY:-$HOME/.config/opencode/keys/hosting01-deploy-ed25519}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o BatchMode=yes -o IdentitiesOnly=yes -i "$KEY")
REPLACE=""
SKIP_BUILD=0

while [ $# -gt 0 ]; do
    case "$1" in
        --replace)  REPLACE="${2:?--replace needs a host name}"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

SSH_NODE=(ssh "${SSH_OPTS[@]}" "root@${NODE}")

echo "== 1/5 dashboard artifact"
if [ "$SKIP_BUILD" = 0 ]; then
    ( cd "$ROOT/../hosting-api" && CARGO_TARGET_DIR="$HOME/.cache/cargo-target" \
        cargo build --release -p hosting-api )
    mkdir -p "$ROOT/../hosting-api/target/release"
    cp "$HOME/.cache/cargo-target/release/hosting-api" \
       "$ROOT/../hosting-api/target/release/hosting-api"
    ( cd "$ROOT/../hosting-dashboard" && bun install --frozen-lockfile --production )
else
    echo "   skipped (--skip-build)"
fi

echo "== 2/5 cloud-init snippets"
"$ROOT/ops/hosting/deploy-cloudinit.sh" "$NODE"

echo "== 3/5 terraform"
cd "$ROOT/terraform/hosting"
eval "$(ssh-agent -s)" >/dev/null
ssh-add "$KEY" >/dev/null
export TF_VAR_pve_endpoint="https://${NODE}:8006/"
# token file holds the full "terraform@pve!terraform=<secret>" identity
PVE_TOKEN="$(cat "$HOME/.config/opencode/keys/pve-hosting01-terraform")"
export TF_VAR_pve_api_token="$PVE_TOKEN"
export TF_VAR_datastore_id="local-zfs"
export TF_VAR_docker01_memory_mib=20480
DEPLOY_PUB="$(tr -d '\n' < "$KEY.pub" | sed 's/^/"/;s/$/"/')"
export TF_VAR_ssh_admin_keys="[$DEPLOY_PUB]"

TF_ARGS=(-input=false -auto-approve)
if [ -n "$REPLACE" ]; then
    case "$REPLACE" in
        docker01) TF_ARGS+=(-replace=proxmox_virtual_environment_vm.docker01) ;;
        docker02) TF_ARGS+=(-replace=proxmox_virtual_environment_vm.docker02) ;;
        *) echo "unknown --replace target" >&2; exit 2 ;;
    esac
fi
terraform apply "${TF_ARGS[@]}"
cd "$ROOT"

echo "== 4/5 resolve mgmt IPs (guest agent)"
HV="$ROOT/ansible/inventory/host_vars"
for VM in 110 120; do
    # wait for the agent (fresh clones need a boot cycle)
    IP=""
    for _ in $(seq 1 40); do
        IP="$("${SSH_NODE[@]}" "qm guest cmd $VM network-get-interfaces 2>/dev/null" \
            | python3 -c "
import json,sys
try:
    for i in json.load(sys.stdin):
        for a in i.get('ip-addresses', []):
            if a['ip-address-type']=='ipv4' and a['ip-address'].startswith('192.168.0.'):
                print(a['ip-address']); break
except Exception: pass" | head -1)"
        [ -n "$IP" ] && break
        sleep 10
    done
    [ -n "$IP" ] || { echo "no mgmt IP for VM $VM" >&2; exit 1; }
    NAME="$( [ "$VM" = 110 ] && echo docker01 || echo docker02 )"
    # update the committed host_vars (the last-known-truth record); keep
    # every other line (hosting_data_disk_by_id, tenants, ...)
    sed -i "s|^ansible_host:.*|ansible_host: $IP|" "$HV/$NAME.yml"
    echo "resolved $NAME -> $IP"
done

echo "== 5/5 ansible bootstrap"
cd "$ROOT/ansible"
ansible-playbook -i inventory/hosts.yml playbooks/hosting_bootstrap.yml
cd "$ROOT"

echo "== 6/5 verify (services + endpoints per host)"
VERIFY_OK=1
for VM in 110 120; do
    NAME="$( [ "$VM" = 110 ] && echo docker01 || echo docker02 )"
    IP="$(grep -A3 "^$NAME:" "$ROOT/ansible/inventory/host_vars/$NAME.yml" \
        | grep ansible_host | awk '{print $2}')"
    [ -n "$IP" ] || { echo "verify: no IP for $NAME"; VERIFY_OK=0; continue; }
    RESULT="$(ssh "${SSH_OPTS[@]}" "wyatt@$IP" '
        systemctl is-active docker caddy sis-hosting-api sis-hosting-dashboard | sort -u
        printf "api:%s " "$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8484/healthz)"
        printf "dash:%s" "$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:4321/)"
        echo
    ' 2>&1 | tail -2)"
    echo "  $NAME: $(echo "$RESULT" | tr '\n' ' ')"
    if echo "$RESULT" | grep -qx "active" && echo "$RESULT" | grep -q "api:200 dash:200"; then
        continue
    fi
    VERIFY_OK=0
done

if [ "$VERIFY_OK" != 1 ]; then
    echo "DEPLOY VERIFY FAILED — services/endpoints unhealthy; do not onboard tenants" >&2
    exit 1
fi

echo "== deploy complete (verified)"
