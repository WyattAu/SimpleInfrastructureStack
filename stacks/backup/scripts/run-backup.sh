#!/bin/sh
# Backup Script for SimpleInfrastructureStack
# Runs inside backup-cron-trigger container, triggers backup-restic

set -euo pipefail

echo "[$(date -Iseconds)] Starting backup..."

# Clear stale locks from interrupted backups (e.g., container recreation during deploy)
docker exec backup-restic restic unlock --remove-all 2>/dev/null || true

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

# Verify restore works by restoring a single known file and checking its content
echo "[$(date -Iseconds)] Verifying restore..."
docker exec backup-restic sh -c '
  rm -rf /tmp/restore-verify 2>/dev/null || true
  restic restore latest --target /tmp/restore-verify --include "/data/accounting/akaunting/README.md"
  if [ -f /tmp/restore-verify/data/accounting/akaunting/README.md ]; then
    echo "  Restore verification PASSED (file exists, $(wc -c < /tmp/restore-verify/data/accounting/akaunting/README.md) bytes)"
    rm -rf /tmp/restore-verify
  else
    echo "  Restore verification FAILED (file not found)"
    rm -rf /tmp/restore-verify
    exit 1
  fi
'

# --- Offsite sync (if configured) ---
# Copies all snapshots to a remote repository (e.g., Backblaze B2).
# Enable by setting OFFSITE_REPO env var in the cron-trigger service.
# Example OFFSITE_REPO value: s3:https://s3.us-west-004.backblazeb2.com/bucket-name/repo
if [ -n "${OFFSITE_REPO:-}" ]; then
    echo "[$(date -Iseconds)] Syncing to offsite repository: ${OFFSITE_REPO}"
    docker exec -e AWS_ACCESS_KEY_ID="${OFFSITE_AWS_KEY:-}" \
                 -e AWS_SECRET_ACCESS_KEY="${OFFSITE_AWS_SECRET:-}" \
                 backup-restic restic copy "${RESTIC_REPOSITORY}" "${OFFSITE_REPO}"
    echo "[$(date -Iseconds)] Offsite sync completed."
else
    echo "[$(date -Iseconds)] No offsite repository configured (set OFFSITE_REPO to enable)."
fi

echo "[$(date -Iseconds)] Backup completed successfully."
