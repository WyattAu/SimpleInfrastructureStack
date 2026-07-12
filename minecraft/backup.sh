#!/bin/bash
# Daily world backup for Minecraft server on CachyOS
# Runs via systemd user timer: minecraft-backup.timer (03:00 daily)
set -euo pipefail

CONTAINER="mc-purpur"
BACKUP_DIR="/home/wyatt/mc-backups"
TAR_DIR="${BACKUP_DIR}/world-tar"
RESTIC_REPO="${BACKUP_DIR}/restic"
RESTIC_PASSWORD="Ki/+lLYMLu0/0sCBsKpxpISjOY2tBjcIBaFL31Moi+4+"
RESTIC_BIN="${HOME}/.local/bin/restic"
LOG="${BACKUP_DIR}/backup.log"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DATE=$(date +%Y%m%d)

export RESTIC_PASSWORD

mkdir -p "$TAR_DIR"
echo "[${TS}] Starting MC backup..." >> "$LOG"

# Step 1: Create world snapshot via incus exec (avoids permission issues)
# The server keeps running during backup — tar reads consistent files
echo "[${TS}] Creating world tarball..." >> "$LOG"
incus exec "$CONTAINER" -- tar czf - -C /opt/minecraft \
  world world_nether world_the_end \
  2>/dev/null > "${TAR_DIR}/world-${DATE}.tar.gz"

# Also backup server.properties and plugin configs
incus exec "$CONTAINER" -- tar czf - -C /opt/minecraft \
  server.properties eula.txt plugins \
  2>/dev/null > "${TAR_DIR}/config-${DATE}.tar.gz"

echo "[${TS}] Tarball size: $(du -sh ${TAR_DIR}/world-${DATE}.tar.gz | awk '{print $1}')" >> "$LOG"

# Step 2: Restic backup
echo "[${TS}] Uploading to restic..." >> "$LOG"
"$RESTIC_BIN" -r "$RESTIC_REPO" backup "$TAR_DIR" \
  --tag minecraft \
  --tag "mc-${DATE}" 2>&1 >> "$LOG"

# Step 3: Retention (14 daily, 4 weekly, 2 monthly)
"$RESTIC_BIN" -r "$RESTIC_REPO" forget \
  --keep-daily 14 \
  --keep-weekly 4 \
  --keep-monthly 2 \
  --prune 2>&1 >> "$LOG"

# Step 4: Clean old tarballs (keep 7 days locally)
find "$TAR_DIR" -name "*.tar.gz" -mtime +7 -delete 2>/dev/null || true

echo "[${TS}] MC backup complete." >> "$LOG"
