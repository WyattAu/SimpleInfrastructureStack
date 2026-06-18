#!/bin/bash
# backup-verify.sh — Verify backup recency and export metrics
# Checks if latest backup is within expected interval (25 hours for daily)
#
# Usage: backup-verify.sh

RESTIC_REPO="/mnt/pool_HDD_x2/tank/datasources/sis/backups/restic-repo-new"
RESTIC_PASSWORD="Ki/+lLYMLu0/0sCBsKpxpISjOY2tBjcIBaFL31Moi+4="
METRICS_FILE="/mnt/pool_HDD_x2/tank/datasources/sis/backups/backup.prom"
MAX_AGE_HOURS=25

# Get latest snapshot time
LATEST=$(RESTIC_PASSWORD="$RESTIC_PASSWORD" restic -r "$RESTIC_REPO" snapshots --latest 1 --compact 2>/dev/null | tail -1 | awk '{print $2" "$3}')

if [ -z "$LATEST" ]; then
    echo "ERROR: No snapshots found"
    STATUS=0
    AGE=999999
else
    # Convert to epoch
    SNAPSHOT_EPOCH=$(date -d "$LATEST" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    AGE_HOURS=$(( (NOW_EPOCH - SNAPSHOT_EPOCH) / 3600 ))
    
    if [ "$AGE_HOURS" -le "$MAX_AGE_HOURS" ]; then
        STATUS=1
        echo "OK: Latest backup $AGE_HOURS hours ago ($LATEST)"
    else
        STATUS=0
        echo "WARNING: Latest backup $AGE_HOURS hours ago ($LATEST)"
    fi
    AGE=$AGE_HOURS
fi

# Get snapshot count
COUNT=$(RESTIC_PASSWORD="$RESTIC_PASSWORD" restic -r "$RESTIC_REPO" snapshots --compact 2>/dev/null | tail -1 | awk '{print $1}')

# Write metrics
cat > "$METRICS_FILE" << EOF
# HELP infra_backup_last_success Whether last backup was within acceptable window
# TYPE infra_backup_last_success gauge
infra_backup_last_success $STATUS

# HELP infra_backup_age_hours Age of latest backup in hours
# TYPE infra_backup_age_hours gauge
infra_backup_age_hours ${AGE:-999999}

# HELP infra_backup_snapshots_total Total number of snapshots
# TYPE infra_backup_snapshots_total gauge
infra_backup_snapshots_total ${COUNT:-0}

# HELP infra_backup_last_check Timestamp of last check
# TYPE infra_backup_last_check gauge
infra_backup_last_check $(date +%s)
EOF

echo "Backup metrics written"
