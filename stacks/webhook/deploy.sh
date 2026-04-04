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
if [ ! -d "$REPO_DIR/.git" ]; then
    log "Cloning repository..."
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
else
    log "Pulling latest from $BRANCH..."
    cd "$REPO_DIR"
    PRE_DEPLOY_SHA=$(git rev-parse HEAD)
    git fetch origin "$BRANCH"
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

# 3. Deploy stacks
log "Running Ansible deploy..."
cd "$REPO_DIR"
ansible-playbook ansible/playbooks/deploy.yml \
    -i ansible/inventory/hosts.yml 2>&1
DEPLOY_EXIT=$?

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
