#!/bin/bash
# Daily world backup for Minecraft server on CachyOS
# Cron: 0 3 * * * /home/wyatt/minecraft-backup.sh
set -euo pipefail

CONTAINER="mc-purpur"
WORLD_DIR="/var/lib/incus/storage-pools/default/containers/${CONTAINER}/rootfs/opt/minecraft"
BACKUP_DIR="/home/wyatt/mc-backups"
RESTIC_REPO="${BACKUP_DIR}/restic"
RESTIC_PASS="Ki/+lLYMLu0/0sCBsKpxpISjOY2tBjcIBaFL31Moi+4+"
LOG="/home/wyatt/mc-backup.log"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "[${TS}] Starting MC backup..." >> "$LOG"

# Init repo if needed
export RESTIC_PASSWORD="$RESTIC_PASS"
restic -r "$RESTIC_REPO" snapshots > /dev/null 2>&1 || restic -r "$RESTIC_REPO" init

# Backup world data
restic -r "$RESTIC_REPO" backup "$WORLD_DIR" \
  --tag minecraft \
  --tag mc-purpur \
  --tag world 2>&1 >> "$LOG"

# Keep 14 daily, 4 weekly, 2 monthly snapshots
restic -r "$RESTIC_REPO" forget \
  --keep-daily 14 \
  --keep-weekly 4 \
  --keep-monthly 2 \
  --prune 2>&1 >> "$LOG"

# Write metrics for monitoring
TEXTFILE="/mnt/pool_HDD_x2/tank/datasources/sis/appdata/monitoring/textfile-collector/mc-backup.prom"
# Can't write to TrueNAS from CachyOS directly — write locally and let node-exporter pick it up
# For now, just log
echo "[${TS}] MC backup complete." >> "$LOG"
