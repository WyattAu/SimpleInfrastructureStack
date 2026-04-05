#!/bin/sh
# Backup Script for SimpleInfrastructureStack
# Runs inside backup-cron-trigger container, triggers backup-restic

set -euo pipefail

echo "[$(date -Iseconds)] Starting backup..."

# Initialize repository if it doesn't exist
docker exec backup-restic restic snapshots 2>/dev/null || \
  docker exec backup-restic restic init

# Create backup
docker exec backup-restic restic backup \
  /data \
  --tag auto \
  --tag "$(date +%Y-%m-%d)" \
  --exclude-if-present ".nobackup"

# Prune old backups according to retention policy
docker exec backup-restic restic forget \
  --keep-hourly "${RESTIC_KEEP_HOURLY:-24}" \
  --keep-daily "${RESTIC_KEEP_DAILY:-7}" \
  --keep-weekly "${RESTIC_KEEP_WEEKLY:-4}" \
  --keep-monthly "${RESTIC_KEEP_MONTHLY:-6}" \
  --keep-yearly "${RESTIC_KEEP_YEARLY:-3}" \
  --prune

# Check repository health
docker exec backup-restic restic check

echo "[$(date -Iseconds)] Backup completed successfully."
