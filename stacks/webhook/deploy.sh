#!/bin/bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-/mnt/pool_HDD_x2/infra/stacks}"
SECRETS_DIR="${SECRETS_DIR:-/mnt/pool_HDD_x2/infra/secrets}"
LOG_FILE="/var/log/infra-deploy.log"
LOCK_FILE="/var/run/infra-deploy.lock"
REPO_URL="${REPO_URL:-https://github.com/WyattAu/SimpleInfrastructureStack.git}"
BRANCH="${BRANCH:-main}"

# Prevent concurrent deploys — flock exits immediately if another deploy is running
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Another deploy is already running, exiting." >&2
    exit 1
fi

# Log all output to file and stdout (fd 9 stays open for the lock)
exec > >(tee -a "$LOG_FILE") 2>&1

# Git SSH config for deploy key
export GIT_SSH_COMMAND="ssh -i /root/.ssh/deploy_key -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o BatchMode=yes"
export ANSIBLE_ROLES_PATH="${REPO_DIR}/ansible/roles"
export ANSIBLE_CONFIG="${REPO_DIR}/ansible/ansible.cfg"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== DEPLOY STARTED ==="

# 1. Ensure repo exists and pull latest
# Track changed files to handle bind-mount inode breakage.
# git reset --hard replaces files atomically (new inode), but Docker
# bind mounts in running containers still reference the old inode.
# After deploy, we must restart containers whose bind-mounted config
# files changed so they pick up the new file content.
CHANGED_FILES=""
if [ ! -d "$REPO_DIR/.git" ]; then
    log "Cloning repository..."
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
else
    log "Pulling latest from $BRANCH..."
    cd "$REPO_DIR"
    PRE_DEPLOY_SHA=$(git rev-parse HEAD)
    log "Previous HEAD: $PRE_DEPLOY_SHA"
    git fetch origin "$BRANCH"
    ORIGIN_SHA=$(git rev-parse "origin/$BRANCH")
    log "Origin $BRANCH: $ORIGIN_SHA"
    # Capture changed files before reset (diff between HEAD and origin)
    CHANGED_FILES=$(git diff --name-only "$PRE_DEPLOY_SHA" "$ORIGIN_SHA" 2>/dev/null || true)
    log "Changed files ($([ -n "$CHANGED_FILES" ] && echo "$(echo "$CHANGED_FILES" | wc -l) files" || echo "none")): $(echo "$CHANGED_FILES" | tr '\n' ' ')"
    git reset --hard "origin/$BRANCH"
fi
log "Code at: $(cd "$REPO_DIR" && git log --oneline -1)"

# 2. Decrypt secrets
log "Decrypting secrets..."
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
DECRYPTED=0
SOPS_CONFIG_FILE="$REPO_DIR/.sops.yaml"
SOPS_CONFIG_OPT=""
if [ -f "$SOPS_CONFIG_FILE" ]; then
    SOPS_CONFIG_OPT="--config $SOPS_CONFIG_FILE"
    log "Using SOPS config: $SOPS_CONFIG_FILE"
fi

for encrypted in "$REPO_DIR"/secrets/*.env.encrypted; do
    [ -f "$encrypted" ] || continue
    stack=$(basename "$encrypted" .env.encrypted)
    if sops --decrypt --input-type dotenv --output-type dotenv \
        $SOPS_CONFIG_OPT \
        "$encrypted" > "$SECRETS_DIR/$stack.env" 2>/dev/null; then
        chmod 600 "$SECRETS_DIR/$stack.env"
        log "  Decrypted: $stack"
        DECRYPTED=$((DECRYPTED + 1))
    else
        log "  WARNING: Failed to decrypt $stack"
    fi
done
log "Decrypted $DECRYPTED secret files"

# 2b. Expand template files that reference secret env vars
# Source decrypted env files to make vars available to envsubst.
# We only source files that contain NTFY_TOPIC (or other template refs).
log "Expanding template files..."
set -a
for env_file in "$SECRETS_DIR"/*.env; do
    [ -f "$env_file" ] || continue
    # Only source if it contains vars referenced by templates
    if grep -q 'NTFY_' "$env_file" 2>/dev/null; then
        set -o allexport
        . "$env_file"
    fi
done
for stack_dir in "$REPO_DIR"/stacks/*/; do
    [ -d "$stack_dir" ] || continue
    find "$stack_dir" -name '*.tmpl' -exec sh -c '
        for tmpl; do
            target="${tmpl%.tmpl}"
            envsubst < "$tmpl" > "$target"
        done
    ' _ {} +
done
set +a

# 3. Deploy stacks
log "Running Ansible deploy..."
cd "$REPO_DIR"
ansible-playbook ansible/playbooks/deploy.yml \
    -i ansible/inventory/hosts.yml 2>&1
DEPLOY_EXIT=$?

# 3b. Restart containers with changed bind-mounted config files.
# Docker Compose only recreates containers when the compose file changes,
# not when bind-mounted config files change. git reset --hard breaks
# inode linkage, so running containers see stale content until restart.
if [ $DEPLOY_EXIT -eq 0 ] && [ -n "$CHANGED_FILES" ]; then
    log "Checking for containers needing restart due to config changes..."
    RESTARTED=0
    # Map: repo-relative file path -> container name
    # Only files under stacks/ that are bind-mounted into containers.
    for changed_file in $CHANGED_FILES; do
        case "$changed_file" in
            stacks/monitoring/prometheus/prometheus.yml|stacks/monitoring/prometheus/alert_rules.yml)
                RESTART_LIST="${RESTART_LIST:+$RESTART_LIST }monitoring-prometheus"
                ;;
            stacks/monitoring/grafana/provisioning/*)
                RESTART_LIST="${RESTART_LIST:+$RESTART_LIST }monitoring-grafana"
                ;;
            stacks/monitoring/promtail/config.yml)
                RESTART_LIST="${RESTART_LIST:+$RESTART_LIST }monitoring-promtail"
                ;;
            stacks/monitoring/loki/config.yml)
                RESTART_LIST="${RESTART_LIST:+$RESTART_LIST }monitoring-loki"
                ;;
            stacks/proxy/config/*)
                RESTART_LIST="${RESTART_LIST:+$RESTART_LIST }proxy-well-known-server"
                ;;
            stacks/storage/config/*)
                RESTART_LIST="${RESTART_LIST:+$RESTART_LIST }storage-ocis"
                ;;
            stacks/backup/scripts/*)
                RESTART_LIST="${RESTART_LIST:+$RESTART_LIST }backup-cron-trigger"
                ;;
            stacks/webhook/deploy.sh|stacks/webhook/hooks.yaml.tmpl)
                # Skip — webhook is the container running this script.
                # It will pick up changes on next deploy trigger.
                log "  Skipping webhook container (self): $changed_file"
                ;;
        esac
    done
    # Deduplicate and restart
    if [ -n "${RESTART_LIST:-}" ]; then
        UNIQUE_RESTART=$(echo "$RESTART_LIST" | tr ' ' '\n' | sort -u)
        for container in $UNIQUE_RESTART; do
            log "  Restarting $container (bind-mounted config changed)"
            docker restart "$container" 2>&1 || log "  WARNING: Failed to restart $container"
            RESTARTED=$((RESTARTED + 1))
        done
        log "Restarted $RESTARTED container(s) for config changes"
        # Brief pause for containers to become ready before health checks
        sleep 5
    fi
fi

# 4. Health check
HEALTH_EXIT=0
if [ $DEPLOY_EXIT -eq 0 ]; then
    log "Running health checks..."
    ansible-playbook ansible/playbooks/health_check.yml \
        -i ansible/inventory/hosts.yml 2>&1
    HEALTH_EXIT=$?
fi

# 5. Cleanup secrets from disk
log "Cleaning up decrypted secrets..."
find "$SECRETS_DIR" -name "*.env" -type f -delete 2>/dev/null || true

# 6. Report result
if [ $DEPLOY_EXIT -eq 0 ] && [ $HEALTH_EXIT -eq 0 ]; then
    log "=== DEPLOY COMPLETED SUCCESSFULLY ==="
    exit 0
else
    log "=== DEPLOY FAILED (deploy=$DEPLOY_EXIT, health=$HEALTH_EXIT) ==="
    # Rollback to previous commit if available
    if [ -n "${PRE_DEPLOY_SHA:-}" ]; then
        log "Rolling back to $PRE_DEPLOY_SHA..."
        cd "$REPO_DIR"
        git reset --hard "$PRE_DEPLOY_SHA"
        log "Rollback complete. Re-deploying previous version..."
        ansible-playbook ansible/playbooks/deploy.yml \
            -i ansible/inventory/hosts.yml 2>&1
        ROLLBACK_EXIT=$?
        if [ $ROLLBACK_EXIT -eq 0 ]; then
            log "=== ROLLBACK SUCCEEDED ==="
        else
            log "=== ROLLBACK ALSO FAILED ==="
        fi
    else
        log "No previous commit to rollback to (first deploy or fresh clone)."
    fi
    exit 1
fi
