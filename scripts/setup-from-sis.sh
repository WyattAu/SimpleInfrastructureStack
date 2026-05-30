#!/bin/bash
# setup-from-sis.sh
# Idempotent setup script that handles everything NOT in docker-compose.
# Run AFTER `docker compose up -d` from stacks/operations/.
# Safe to run multiple times — skips already-configured steps.
#
# Usage: sudo bash setup-from-sis.sh

set -euo pipefail
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
ok() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${RED}✗${NC} $1"; }

echo "=== SIS Post-Deploy Setup ==="

# ── 1. Docker data-root on SSD ──────────────────────────────
if grep -q 'ssd-docker' /etc/docker/daemon.json 2>/dev/null; then
  ok "Docker already on SSD"
else
  echo "Migrating Docker to SSD..."
  if sudo zfs list boot-pool/docker >/dev/null 2>&1; then
    ok "SSD dataset exists"
  else
    echo "Creating SSD dataset..."
    sudo zfs create -o mountpoint=/mnt/ssd-docker boot-pool/docker
  fi

  echo "Stopping Docker..."
  sudo systemctl stop docker.socket 2>/dev/null || true
  sudo systemctl stop docker

  echo "Copying Docker data to SSD (this takes ~20 min)..."
  sudo zfs snapshot pool_HDD_x2/ix-apps/docker@setup
  sudo zfs send pool_HDD_x2/ix-apps/docker@setup | sudo zfs recv -F boot-pool/docker
  sudo zfs destroy pool_HDD_x2/ix-apps/docker@setup

  echo "Updating daemon.json..."
  sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
  sudo sed -i 's|/mnt/.ix-apps/docker|/mnt/ssd-docker|' /etc/docker/daemon.json

  echo "Starting Docker on SSD..."
  sudo systemctl start docker
  ok "Docker migrated to SSD"
fi

# ── 2. Crontab entries ──────────────────────────────────────
CRON_FILE="/etc/crontab"
add_cron() {
  local entry="$1"
  if ! sudo grep -qF "$entry" "$CRON_FILE" 2>/dev/null; then
    echo "$entry" | sudo tee -a "$CRON_FILE" >/dev/null
    ok "Cron: $(echo $entry | cut -d'/' -f4 | cut -d' ' -f1)"
  else
    ok "Cron: $(echo $entry | cut -d'/' -f4 | cut -d' ' -f1) (already exists)"
  fi
}

SCRIPTS="/mnt/pool_HDD_x2/infra/scripts"
add_cron "*/30 * * * * ${SCRIPTS}/cleanup-ci-containers.sh >> /mnt/pool_HDD_x2/infra/logs/ci-cleanup.log 2>&1"
add_cron "*/15 * * * * root ${SCRIPTS}/fix-stuck-jobs.sh"
add_cron "0 4 * * * root ${SCRIPTS}/prepull-base-images.sh >> /mnt/pool_HDD_x2/infra/logs/prepull-images.log 2>&1"
add_cron "0 3 * * 0 root ${SCRIPTS}/restart-forgejo-weekly.sh >> /mnt/pool_HDD_x2/infra/logs/forgejo-restart.log 2>&1"

# ── 3. Runner registration ──────────────────────────────────
echo ""
echo "=== Runner Registration ==="
echo "Runner .runner files are at:"
echo "  /mnt/pool_HDD_x2/tank/datasources/sis/appdata/operations/<runner>/.runner"
echo ""
echo "If redeploying, runners need to be re-registered via Forgejo API:"
echo "  POST /api/v1/admin/actions/runners"
echo "  Body: {\"name\": \"runner-questhive\", \"labels\": [\"questhive\"]}"
echo ""
echo "=== Setup Complete ==="
echo "Verify: docker info | grep 'Docker Root'"
echo "Should show: /mnt/ssd-docker"
