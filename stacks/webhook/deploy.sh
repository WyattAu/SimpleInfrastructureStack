#!/bin/bash
# deploy.sh — Thin wrapper for ansible-playbook site.yml.
#
# All deployment logic (git sync, SOPS decrypt, template expansion,
# Docker Compose, bind-mount restart, health checks, rollback, cleanup)
# has been migrated to Ansible roles and playbooks.
#
# This script handles only:
#   1. Concurrency control via flock (prevents parallel deploys)
#   2. Output logging to /var/log/infra-deploy.log
#   3. Setting environment variables needed by Ansible
#   4. Calling ansible-playbook site.yml

set -euo pipefail

REPO_DIR="${REPO_DIR:-/mnt/pool_HDD_x2/infra/stacks}"
LOG_FILE="/var/log/infra-deploy.log"
LOCK_FILE="/var/run/infra-deploy.lock"

# Prevent concurrent deploys — flock exits immediately if another deploy is running
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Another deploy is already running, exiting." >&2
    exit 1
fi

# Log all output to file and stdout (fd 9 stays open for the lock)
exec > >(tee -a "$LOG_FILE") 2>&1

# Environment variables for Ansible and git
export GIT_SSH_COMMAND="ssh -i /root/.ssh/deploy_key -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o BatchMode=yes"
export ANSIBLE_ROLES_PATH="${REPO_DIR}/ansible/roles"
export ANSIBLE_CONFIG="${REPO_DIR}/ansible/ansible.cfg"

ansible-playbook "${REPO_DIR}/ansible/playbooks/site.yml" \
    -i "${REPO_DIR}/ansible/inventory/hosts.yml"
