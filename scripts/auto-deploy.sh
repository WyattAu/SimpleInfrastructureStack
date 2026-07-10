#!/usr/bin/env bash
# Auto-deploy script for SIS infrastructure.
# Triggered by Forgejo CI or manually.
# Pulls latest code and runs Ansible deployment.

set -euo pipefail

REPO_DIR="/mnt/pool_HDD_x2/infra/stacks"
ANSIBLE_DIR="${REPO_DIR}/ansible"
LOG_FILE="/mnt/pool_HDD_x2/tank/datasources/sis/backups/deploy.log"
DEPLOY_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "[${DEPLOY_TS}] Starting auto-deploy..." | tee -a "$LOG_FILE"

cd "$REPO_DIR"

# Pull latest code
echo "Pulling latest code..."
git fetch origin main
BEFORE=$(git rev-parse HEAD)
git reset --hard origin/main
AFTER=$(git rev-parse HEAD)

if [ "$BEFORE" = "$AFTER" ]; then
    echo "[${DEPLOY_TS}] No changes detected, skipping deploy." | tee -a "$LOG_FILE"
    exit 0
fi

echo "[${DEPLOY_TS}] Deploying $(git log --oneline -1)" | tee -a "$LOG_FILE"

# Run Ansible deployment
cd "$ANSIBLE_DIR"
if [ -f "playbooks/site.yml" ]; then
    echo "Running Ansible playbook..."
    ansible-playbook playbooks/site.yml \
        -i inventory/hosts.yml \
        --extra-vars "deploy_timestamp=${DEPLOY_TS}" \
        2>&1 | tee -a "$LOG_FILE"
    
    # Record deploy metric
    TEXTFILE_DIR="/mnt/pool_HDD_x2/tank/datasources/sis/appdata/monitoring/textfile-collector"
    echo "sis_deploy_timestamp $(date +%s)" > "${TEXTFILE_DIR}/deploy.prom"
    echo "sis_deploy_success 1" >> "${TEXTFILE_DIR}/deploy.prom"
    
    echo "[${DEPLOY_TS}] Deploy completed successfully." | tee -a "$LOG_FILE"
else
    echo "[${DEPLOY_TS}] No site.yml found, deploy skipped." | tee -a "$LOG_FILE"
fi
