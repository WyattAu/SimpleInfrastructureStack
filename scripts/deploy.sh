#!/usr/bin/env bash
# deploy.sh — Manual one-command deployment to TrueNAS
#
# Usage: ./scripts/deploy.sh [BRANCH]
#   BRANCH  Git branch to deploy (default: main)
#
# Flags:
#   --skip-health    Skip health checks (faster, for emergencies)
#   --dry-run        Show what would be deployed without making changes
#   -h, --help       Show this help
#
# Provides a manual deployment path when the TrueNAS webhook is unavailable.
# Mirrors the Ansible playbook pipeline (ansible/playbooks/site.yml):
#
#   Phase 1: Prepare
#     - Record current SHA for rollback
#     - Git fetch + reset --hard to origin/<branch>
#     - SOPS decrypt all .env.encrypted -> .secrets.tmp/
#     - Ensure Docker networks (traefik_net, backend_net, data_net)
#     - Expand Jinja2 templates ({{ VAR }} -> values)
#     - Detect bind-mount changes -> schedule container restarts
#
#   Phase 2: Deploy
#     - Sync Homepage config from git to data directory (non-critical)
#     - docker compose up for all 20 stacks
#     - Fix tunnel credentials.json ownership (UID 65532)
#     - Restart containers with changed bind-mounted configs
#
#   Phase 3: Post-deploy (skipped — see notes)
#     Keycloak SMTP and Hookshot config are non-critical API interactions.
#     Run the full ansible playbook if these need reconfiguration.
#
#   Phase 4: Health Check
#     - Poll all containers until healthy (15 min timeout per container)
#
#   Phase 5: Cleanup
#     - Remove all decrypted secrets from disk (trap EXIT)
#
# Error handling:
#   - flock(1) prevents concurrent deployments
#   - trap EXIT always cleans up decrypted secrets
#   - Deploy failure triggers git rollback + redeploy from previous commit
#
# Prerequisites:
#   - SSH key: ~/.ssh/id_ed25519
#   - SSH access: truenas_admin@192.168.1.3
#   - SOPS age key on TrueNAS: /root/.config/sops/age/keys.txt
#   - Docker Compose V2 on TrueNAS (or V1 as docker-compose)
#   - Python 3 on TrueNAS (for Jinja2 template expansion)

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_USER="truenas_admin"
SSH_HOST="192.168.1.3"
BRANCH="main"
SKIP_HEALTH=false
DRY_RUN=false
LOCK_FILE="/tmp/infra-deploy.lock"

SSH_OPTS=(
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=10
)

# ─── Parse arguments ────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-health) SKIP_HEALTH=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        -*) echo "Unknown flag: $1 (use --help)" >&2; exit 1 ;;
        *)  BRANCH="$1"; shift ;;
    esac
done

# ─── Logging ─────────────────────────────────────────────────────────────

log()       { echo "[DEPLOY $(date '+%H:%M:%S')] $*"; }
log_phase() { echo ""; echo "====== $* ======"; echo ""; }
log_ok()    { echo "  [OK]   $*"; }
log_warn()  { echo "  [WARN] $*"; }
log_fail()  { echo "  [FAIL] $*" >&2; }

# ─── Concurrency control (flock) ──────────────────────────────────────────

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "[ERROR] Another deployment is in progress (lock: $LOCK_FILE)" >&2
    exit 1
fi
trap 'exec 200>&- 2>/dev/null; rm -f "$LOCK_FILE"' EXIT

# ─── SSH connectivity check ───────────────────────────────────────────────

log "Checking SSH connectivity..."
if ! ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" true 2>/dev/null; then
    log_fail "Cannot connect to ${SSH_USER}@${SSH_HOST}"
    exit 1
fi

# ─── Run remote deployment ────────────────────────────────────────────────

log "Starting manual deployment (branch: ${BRANCH})"
$DRY_RUN && log "[DRY RUN] No changes will be made"
START_TIME=$(date +%s)

ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" \
    bash -s -- "$BRANCH" "$SKIP_HEALTH" "$DRY_RUN" << 'REMOTE_SCRIPT'
set -euo pipefail

# ─── Remote arguments ────────────────────────────────────────────────────

BRANCH="${1:-main}"
SKIP_HEALTH="${2:-false}"
DRY_RUN="${3:-false}"
[[ "$SKIP_HEALTH" == "true" ]] && SKIP_HEALTH=true || SKIP_HEALTH=false
[[ "$DRY_RUN" == "true" ]] && DRY_RUN=true || DRY_RUN=false

# ─── Remote paths ────────────────────────────────────────────────────────

REPO_PATH="/mnt/pool_HDD_x2/infra/stacks"
SECRETS_PATH="${REPO_PATH}/.secrets.tmp"
BASE_PATH="${REPO_PATH}/stacks"
DATA_PATH="/mnt/pool_HDD_x2/tank/datasources/sis/appdata"
SOPS_CONFIG="${REPO_PATH}/.sops.yaml"
SHA_FILE="/var/run/infra-deploy-sha"

# ─── Stack deployment order (ansible/inventory/group_vars/all.yml) ────────

STACKS=(
    tunnel security proxy iam monitoring operations
    collaboration storage accounting erpnext project-management utility
    backup vaultwarden rss photos documents vpn books updater
)

# ─── Health check containers (ansible/inventory/group_vars/all.yml) ───────

HEALTH_CONTAINERS=(
    security-crowdsec security-cf-workers-bouncer proxy-oauth2-proxy
    iam-postgres iam-keycloak operations-postgres-forgejo operations-forgejo
    monitoring-victoriametrics monitoring-vmalert monitoring-victorialogs
    monitoring-alertmanager monitoring-grafana monitoring-promtail
    monitoring-kuma monitoring-cadvisor monitoring-node-exporter
    monitoring-postgres-exporter monitoring-redis-exporter
    monitoring-tempo monitoring-blackbox-exporter
    storage-ocis storage-collabora
    collaboration-synapse collaboration-element
    accounting-akaunting accounting-mariadb-exporter
    erpnext-backend erpnext-socketio erpnext-mariadb erpnext-redis
    utility-homepage vaultwarden-server
    rss-postgres rss-freshrss
    photos-postgres photos-valkey photos-server
    documents-postgres documents-redis documents-webserver
    project-management-postgres project-management-rabbitmq
    infra-tunnel vpn-wireguard operations-forgejo-runner
)

# ─── Remote logging ──────────────────────────────────────────────────────

log()       { echo "[REMOTE $(date '+%H:%M:%S')] $*"; }
log_phase() { echo ""; echo "====== $* ======"; echo ""; }
log_ok()    { echo "  [OK]   $*"; }
log_warn()  { echo "  [WARN] $*"; }
log_fail()  { echo "  [FAIL] $*" >&2; }

# ─── Remote state ────────────────────────────────────────────────────────

PRE_DEPLOY_SHA=""
DEPLOY_FAILED=false
CONTAINERS_TO_RESTART=()
CHANGED_FILES=()

# ─── Detect Docker Compose command ───────────────────────────────────────

COMPOSE_CMD=""
if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif docker-compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    log_fail "Docker Compose not found on TrueNAS"
    exit 1
fi
log "Docker Compose: ${COMPOSE_CMD}"

# ─── Cleanup trap: always remove decrypted secrets ────────────────────────

cleanup() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        log "Cleaning up after failure..."
    else
        log "Cleaning up decrypted secrets..."
    fi
    rm -rf "${SECRETS_PATH:?}"/* 2>/dev/null || true
    exit "$rc"
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1: PREPARE
# Mirrors: ansible/roles/prepare/tasks/{main,git_sync,decrypt}.yml
#          ansible/playbooks/site.yml Phase 1a-1d
# ═══════════════════════════════════════════════════════════════════════════

log_phase "Phase 1: Prepare"

# 1a. Record current HEAD for potential rollback
PRE_DEPLOY_SHA=$(git -C "$REPO_PATH" rev-parse HEAD)
log "Current commit: $(git -C "$REPO_PATH" log --oneline -1)"
log "Pre-deploy SHA: ${PRE_DEPLOY_SHA:0:7}"

# 1b. Compute changed files since previous deploy (for bind-mount detection)
PREV_SHA=""
if [ -f "$SHA_FILE" ]; then
    PREV_SHA=$(tr -d '[:space:]' < "$SHA_FILE")
fi
if [ -n "$PREV_SHA" ] && [ "$PREV_SHA" != "$PRE_DEPLOY_SHA" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] && CHANGED_FILES+=("$line")
    done <<< "$(git -C "$REPO_PATH" diff --name-only "${PREV_SHA}..${PRE_DEPLOY_SHA}" 2>/dev/null || true)"
    log "Files changed since last deploy: ${#CHANGED_FILES[@]}"
else
    log "No previous deploy SHA found (first deploy or no changes tracked)"
fi

# 1c. Git sync: fetch + reset --hard
if $DRY_RUN; then
    log "[DRY RUN] Would: git fetch origin && git reset --hard origin/${BRANCH}"
else
    log "Fetching origin..."
    git -C "$REPO_PATH" fetch origin
    log "Resetting to origin/${BRANCH}..."
    git -C "$REPO_PATH" reset --hard "origin/${BRANCH}"
    log "Now at: $(git -C "$REPO_PATH" log --oneline -1)"
fi

# 1d. SOPS decrypt: all .env.encrypted -> .secrets.tmp/*.env
log "Decrypting secrets..."
mkdir -p "$SECRETS_PATH"
DECRYPT_COUNT=0
for f in "$REPO_PATH"/secrets/*.env.encrypted; do
    [ -f "$f" ] || continue
    basename=$(basename "$f" .env.encrypted)
    if $DRY_RUN; then
        log "[DRY RUN] Would decrypt: ${basename}.env"
        DECRYPT_COUNT=$((DECRYPT_COUNT + 1))
        continue
    fi
    if sops --decrypt \
         --input-type dotenv \
         --output-type dotenv \
         --config "$SOPS_CONFIG" \
         --output "${SECRETS_PATH}/${basename}.env" \
         "$f"; then
        DECRYPT_COUNT=$((DECRYPT_COUNT + 1))
    else
        log_fail "Failed to decrypt: ${basename}.env"
        exit 1
    fi
done
log_ok "Decrypted ${DECRYPT_COUNT} secret files"

# 1e. Ensure Docker networks exist (idempotent)
if ! $DRY_RUN; then
    for net in traefik_net backend_net data_net; do
        if ! docker network inspect "$net" >/dev/null 2>&1; then
            docker network create "$net"
            log_ok "Created network: ${net}"
        fi
    done
fi

# 1f. Expand Jinja2 templates using python3
# Replaces ansible.builtin.template from expand_templates.yml.
# Skips hooks.yaml.tmpl (expanded by container entrypoint at startup).
if ! $DRY_RUN; then
    log "Expanding templates..."
    python3 - "$SECRETS_PATH" "$BASE_PATH" << 'PYEOF'
import os, re, glob, sys

secrets_path, base_path = sys.argv[1], sys.argv[2]

for f in sorted(glob.glob(f"{secrets_path}/*.env")):
    with open(f) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip("'\"")
            os.environ[key] = value

count = 0
for f in sorted(glob.glob(f"{base_path}/**/*.tmpl", recursive=True)):
    if "hooks.yaml.tmpl" in f:
        continue
    with open(f) as fh:
        content = fh.read()
    def replacer(m):
        var = m.group(1).strip()
        return os.environ.get(var, m.group(0))
    expanded = re.sub(r"\{\{\s*([\w]+)\s*\}\}", replacer, content)
    out = re.sub(r"\.tmpl$", "", f)
    with open(out, "w") as fh:
        fh.write(expanded)
    count += 1
    print(f"  [OK]   {os.path.basename(out)}")
print(f"Expanded {count} template files")
PYEOF
fi

# 1g. Detect bind-mount changes -> containers needing restart
# Replaces detect_bind_mount_changes.yml
if [ "${#CHANGED_FILES[@]}" -gt 0 ] && ! $DRY_RUN; then
    log "Detecting bind-mount changes..."
    for container in "${HEALTH_CONTAINERS[@]}"; do
        mounts=$(docker inspect \
            --format='{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\x00"}}{{end}}{{end}}' \
            "$container" 2>/dev/null) || continue
        IFS=$'\0' read -r -a mount_sources <<< "$mounts"
        for changed_file in "${CHANGED_FILES[@]}"; do
            full_path="${REPO_PATH}/${changed_file}"
            for mount_src in "${mount_sources[@]}"; do
                [ -z "$mount_src" ] && continue
                if [[ "$full_path" == "$mount_src"* ]]; then
                    match=false
                    for existing in "${CONTAINERS_TO_RESTART[@]+"${CONTAINERS_TO_RESTART[@]}"}"; do
                        if [ "$existing" = "$container" ]; then match=true; break; fi
                    done
                    if ! $match; then
                        CONTAINERS_TO_RESTART+=("$container")
                    fi
                fi
            done
        done
    done
    if [ "${#CONTAINERS_TO_RESTART[@]}" -gt 0 ]; then
        log "Containers to restart for bind-mount changes: ${CONTAINERS_TO_RESTART[*]}"
    fi
fi

# Save current SHA for next deploy
if ! $DRY_RUN; then
    echo "$PRE_DEPLOY_SHA" > "$SHA_FILE"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 2: DEPLOY
# Mirrors: ansible/roles/deploy_stack/tasks/main.yml
#          ansible/roles/deploy_stack/tasks/sync_homepage.yml
#          ansible/roles/deploy_stack/handlers/main.yml
# ═══════════════════════════════════════════════════════════════════════════

log_phase "Phase 2: Deploy"

# 2a. Sync Homepage config (non-critical, ignore_errors in Ansible)
if ! $DRY_RUN; then
    if [ -d "${BASE_PATH}/utility/config" ] && [ -d "${DATA_PATH}/utility/homepage" ]; then
        log "Syncing Homepage config..."
        if docker stop utility-homepage 2>/dev/null; then
            rm -rf "${DATA_PATH}/utility/homepage/config"
            mkdir -p "${DATA_PATH}/utility/homepage/config"
            if cp -a "${BASE_PATH}/utility/config/" "${DATA_PATH}/utility/homepage/config/"; then
                log_ok "Homepage config synced"
            else
                log_warn "Homepage config sync failed — skipping (non-critical)"
            fi
        else
            log_warn "Could not stop Homepage — skipping config sync"
        fi
    fi
fi

# 2b. Deploy stacks via docker compose up
# Uses native docker compose (not Ansible module) to correctly detect
# env_file content changes (e.g., Renovate version bumps).
DEPLOY_FAILED=false
DEPLOYED_COUNT=0
for stack in "${STACKS[@]}"; do
    env_file="${SECRETS_PATH}/${stack}.env"
    versions_file="${REPO_PATH}/stacks/${stack}/versions.env"
    compose_dir="${BASE_PATH}/${stack}"

    if [ ! -f "$env_file" ]; then
        log_warn "No secrets for: ${stack} (skipping)"
        continue
    fi

    if [ ! -d "$compose_dir" ]; then
        log_warn "Stack directory missing: ${compose_dir} (skipping)"
        continue
    fi

    if $DRY_RUN; then
        log "[DRY RUN] Would deploy: ${stack}"
        DEPLOYED_COUNT=$((DEPLOYED_COUNT + 1))
        continue
    fi

    log "Deploying: ${stack}"
    if $COMPOSE_CMD \
        --env-file "$env_file" \
        --env-file "$versions_file" \
        up --detach --pull missing --remove-orphans; then
        DEPLOYED_COUNT=$((DEPLOYED_COUNT + 1))
    else
        log_fail "Failed to deploy stack: ${stack}"
        DEPLOY_FAILED=true
        break
    fi
done

# 2c. Fix tunnel credentials.json ownership
# Cloudflared 2026.3.0 runs as non-root (UID 65532).
if ! $DRY_RUN && [ -f "${BASE_PATH}/tunnel/credentials.json" ]; then
    chown 65532:65532 "${BASE_PATH}/tunnel/credentials.json" 2>/dev/null || true
    chmod 0400 "${BASE_PATH}/tunnel/credentials.json" 2>/dev/null || true
fi

# ─── Rollback on deploy failure ─────────────────────────────────────────

if $DEPLOY_FAILED; then
    log_phase "ROLLBACK"
    log "Deploy failed — rolling back to ${PRE_DEPLOY_SHA:0:7}..."

    git -C "$REPO_PATH" reset --hard "$PRE_DEPLOY_SHA" 2>/dev/null || {
        log_fail "Git rollback failed"
        exit 1
    }

    log "Redeploying all stacks from rollback commit..."
    for stack in "${STACKS[@]}"; do
        env_file="${SECRETS_PATH}/${stack}.env"
        versions_file="${REPO_PATH}/stacks/${stack}/versions.env"
        compose_dir="${BASE_PATH}/${stack}"
        [ -f "$env_file" ] && [ -d "$compose_dir" ] || continue
        $COMPOSE_CMD \
            --env-file "$env_file" \
            --env-file "$versions_file" \
            up --detach --pull missing --remove-orphans 2>/dev/null || {
            log_warn "Rollback deploy failed for: ${stack}"
        }
    done

    log "Rollback complete"
    exit 1
fi

# 2d. Restart containers with changed bind-mounted configs
if [ "${#CONTAINERS_TO_RESTART[@]}" -gt 0 ] && ! $DRY_RUN; then
    log "Restarting ${#CONTAINERS_TO_RESTART[@]} container(s) with changed bind mounts..."
    for container in "${CONTAINERS_TO_RESTART[@]}"; do
        if docker restart "$container" 2>/dev/null; then
            log_ok "Restarted: ${container}"
        else
            log_warn "Failed to restart: ${container}"
        fi
    done
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 3: POST-DEPLOY (skipped in manual deploy)
# Keycloak SMTP (configure_keycloak.yml) and Hookshot (configure_hookshot.yml)
# require complex API interactions. These are non-critical (ignore_errors: true
# in Ansible). Run the full ansible playbook if reconfiguration is needed.
# ═══════════════════════════════════════════════════════════════════════════

log_phase "Phase 3: Post-deploy (skipped)"
log "Keycloak SMTP and Hookshot config skipped — run ansible playbook if needed"

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 4: HEALTH CHECK
# Mirrors: ansible/roles/health_check/tasks/main.yml
# ═══════════════════════════════════════════════════════════════════════════

if $SKIP_HEALTH; then
    log_phase "Phase 4: Health Check (SKIPPED)"
else
    log_phase "Phase 4: Health Check"
    log "Polling ${#HEALTH_CONTAINERS[@]} containers (timeout: 15 min each)"

    HEALTH_FAILED=false
    HEALTHY_COUNT=0
    for container in "${HEALTH_CONTAINERS[@]}"; do
        healthy=false
        for i in $(seq 1 60); do
            state=$(docker inspect \
                --format='{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                "$container" 2>/dev/null) || state="false|none"
            running="${state%%|*}"
            health="${state##*|}"

            if [ "$running" = "true" ] && \
               { [ "$health" = "none" ] || [ "$health" = "healthy" ]; }; then
                healthy=true
                break
            fi

            if [ "$i" -eq 60 ]; then
                log_fail "Unhealthy: ${container} (running=${running}, health=${health})"
                HEALTH_FAILED=true
                break
            fi

            sleep 15
        done

        if $healthy; then
            HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
        fi
    done

    log "Health check: ${HEALTHY_COUNT}/${#HEALTH_CONTAINERS[@]} containers healthy"

    if $HEALTH_FAILED; then
        log_fail "Health check failed for one or more containers"
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 5: COMPLETE
# ═══════════════════════════════════════════════════════════════════════════

log_phase "DEPLOY COMPLETED SUCCESSFULLY"
log "Deployed ${DEPLOYED_COUNT} stacks from ${BRANCH}"
log "Pre-deploy SHA: ${PRE_DEPLOY_SHA:0:7}"
log "Secrets cleanup will happen on exit"
REMOTE_SCRIPT

exit_code=$?
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

if [ $exit_code -eq 0 ]; then
    log "Deployment completed successfully (${ELAPSED}s)"
else
    log "Deployment failed after ${ELAPSED}s (exit code: ${exit_code})" >&2
fi
exit $exit_code
