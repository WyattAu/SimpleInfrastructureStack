#!/bin/bash
set -euo pipefail

REPO_DIR="/opt/stacks"
SECRETS_DIR="/opt/secrets"
LOG_FILE="/var/log/infra-deploy.log"
REPO_URL="https://github.com/WyattAu/SimpleInfrastructureStack.git"
BRANCH="main"

# Git SSH config for deploy key
export GIT_SSH_COMMAND="ssh -i /root/.ssh/deploy_key -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o BatchMode=yes"
export ANSIBLE_ROLES_PATH="${REPO_DIR}/ansible/roles"
export ANSIBLE_CONFIG="${REPO_DIR}/ansible/ansible.cfg"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "=== DEPLOY STARTED ==="

# 1. Ensure repo exists and pull latest
if [ ! -d "$REPO_DIR/.git" ]; then
    log "Cloning repository..."
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
else
    log "Pulling latest from $BRANCH..."
    cd "$REPO_DIR"
    git fetch origin "$BRANCH"
    git reset --hard "origin/$BRANCH"
fi
log "Code at: $(cd "$REPO_DIR" && git log --oneline -1)"

# 2. Decrypt secrets
log "Decrypting secrets..."
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
DECRYPTED=0
for encrypted in "$REPO_DIR"/secrets/*.env.encrypted; do
    [ -f "$encrypted" ] || continue
    stack=$(basename "$encrypted" .env.encrypted)
    if sops --decrypt --input-type dotenv --output-type dotenv \
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
    -i ansible/inventory/hosts.yml \
    -v 2>&1 | tee -a "$LOG_FILE"
DEPLOY_EXIT=${PIPESTATUS[0]}

# 4. Health check
HEALTH_EXIT=0
if [ $DEPLOY_EXIT -eq 0 ]; then
    log "Running health checks..."
    ansible-playbook ansible/playbooks/health_check.yml \
        -i ansible/inventory/hosts.yml \
        -v 2>&1 | tee -a "$LOG_LOG"
    HEALTH_EXIT=${PIPESTATUS[0]}
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
    exit 1
fi
