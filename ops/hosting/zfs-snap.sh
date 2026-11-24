#!/usr/bin/env bash
# ==============================================================================
# zfs-snap.sh — rolling ZFS snapshots for hosting01's VM data (iteration 29).
#
# Installed on hosting01 by ops tooling; systemd timer zfs-snap.timer runs
# it hourly. Keeps 48 hourly + 14 daily snapshots of the local-zfs VM
# datasets — point-in-time recovery against deletion/corruption without
# needing a second node (the NAS replication target and B2 offsite are the
# node-loss layer; snapshots are NOT — same pool).
#
#   zfs-snap.sh            # hourly pass (creates @auto-hourly-<ts>, prunes)
# ==============================================================================
set -euo pipefail

DATASETS=(
    "rpool/data/vm-110-disk-1"   # docker01 tenant data zvol
    "rpool/data/vm-110-disk-0"   # docker01 root (system state)
    "rpool/data/vm-120-disk-0"   # docker02 root
)
KEEP_HOURLY=48
KEEP_DAILY=14

ts() { date -u +"%Y%m%d-%H%M"; }

snap() { zfs snapshot "${1}@auto-hourly-$(ts)" 2>/dev/null || true; }

for ds in "${DATASETS[@]}"; do
    zfs list -H -o name "$ds" >/dev/null 2>&1 || continue
    # hourly
    if ! zfs list -H -o name -t snapshot "$ds@auto-hourly-$(ts)" >/dev/null 2>&1; then
        snap "$ds"
    fi
    # daily: first run of the UTC day
    if ! zfs list -H -o name -t snapshot "$ds@auto-daily-$(date -u +%Y%m%d)" >/dev/null 2>&1; then
        LAST_H=$(zfs list -H -o name -t snapshot "$ds" 2>/dev/null | grep auto-hourly | sort | tail -1)
        [ -n "$LAST_H" ] && zfs snapshot "$ds@auto-daily-$(date -u +%Y%m%d)" 2>/dev/null || true
    fi
    # prune hourly beyond KEEP_HOURLY
    zfs list -H -o name -t snapshot "$ds" | grep auto-hourly | sort \
        | head -n -"$KEEP_HOURLY" | while read -r s; do zfs destroy "$s" 2>/dev/null || true; done
    # prune daily beyond KEEP_DAILY
    zfs list -H -o name -t snapshot "$ds" | grep auto-daily | sort \
        | head -n -"$KEEP_DAILY" | while read -r s; do zfs destroy "$s" 2>/dev/null || true; done
done

echo "snapshots ok $(date -u +%Y-%m-%dT%H:%MZ)"
