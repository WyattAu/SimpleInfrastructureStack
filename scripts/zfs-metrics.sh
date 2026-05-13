#!/bin/sh
# ZFS Pool Metrics Collector
# ==========================
# Collects ZFS pool health, capacity, and scrub status for Prometheus.
# Outputs metrics in Prometheus textfile collector format.
#
# Setup:
#   1. Copy to /usr/local/bin/zfs-metrics.sh
#   2. chmod +x /usr/local/bin/zfs-metrics.sh
#   3. Add cron: echo "*/5 * * * * /usr/local/bin/zfs-metrics.sh" | crontab -
#   4. Ensure TEXTFILE_DIR matches node-exporter --collector.textfile.directory
#
# Tested on: TrueNAS SCALE (ZFS on Linux)
set -eu

TEXTFILE_DIR="${TEXTFILE_DIR:-/mnt/pool_HDD_x2/monitoring/textfile-collector}"
TEXTFILE="$TEXTFILE_DIR/zfs.prom"
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# Header
printf '# HELP sis_zfs_pool_health ZFS pool health status (1=online, 0=degraded/faulted)\n' >> "$TMPFILE"
printf '# TYPE sis_zfs_pool_health gauge\n' >> "$TMPFILE"
printf '# HELP sis_zfs_pool_capacity_bytes ZFS pool total capacity in bytes\n' >> "$TMPFILE"
printf '# TYPE sis_zfs_pool_capacity_bytes gauge\n' >> "$TMPFILE"
printf '# HELP sis_zfs_pool_used_bytes ZFS pool used space in bytes\n' >> "$TMPFILE"
printf '# TYPE sis_zfs_pool_used_bytes gauge\n' >> "$TMPFILE"
printf '# HELP sis_zfs_pool_available_bytes ZFS pool available space in bytes\n' >> "$TMPFILE"
printf '# TYPE sis_zfs_pool_available_bytes gauge\n' >> "$TMPFILE"
printf '# HELP sis_zfs_pool_capacity_pct ZFS pool capacity usage percentage\n' >> "$TMPFILE"
printf '# TYPE sis_zfs_pool_capacity_pct gauge\n' >> "$TMPFILE"
printf '# HELP sis_zfs_pool_scrub_errors ZFS pool scrub error count (0 = clean)\n' >> "$TMPFILE"
printf '# TYPE sis_zfs_pool_scrub_errors gauge\n' >> "$TMPFILE"
printf '# HELP sis_zfs_pool_scrub_timestamp ZFS pool last scrub completion as Unix timestamp\n' >> "$TMPFILE"
printf '# TYPE sis_zfs_pool_scrub_timestamp gauge\n' >> "$TMPFILE"

# Collect metrics for each pool
zpool list -H -p -o name,health,size,allocated,free 2>/dev/null | while IFS=$(printf '\t') read -r pool health size allocated free; do
    # Health: online=1, degraded=0, faulted=0
    if [ "$health" = "ONLINE" ]; then
        health_val=1
    else
        health_val=0
    fi
    printf 'sis_zfs_pool_health{pool="%s"} %d\n' "$pool" "$health_val" >> "$TMPFILE"
    printf 'sis_zfs_pool_capacity_bytes{pool="%s"} %d\n' "$pool" "$size" >> "$TMPFILE"
    printf 'sis_zfs_pool_used_bytes{pool="%s"} %d\n' "$pool" "$allocated" >> "$TMPFILE"
    printf 'sis_zfs_pool_available_bytes{pool="%s"} %d\n' "$pool" "$free" >> "$TMPFILE"

    # Capacity percentage
    if [ "$size" -gt 0 ]; then
        pct=$((allocated * 100 / size))
    else
        pct=0
    fi
    printf 'sis_zfs_pool_capacity_pct{pool="%s"} %d\n' "$pool" "$pct" >> "$TMPFILE"

    # Scrub status
    scrub_errors=0
    scrub_ts=0
    if command -v zpool > /dev/null 2>&1; then
        # Get last scrub date for error count
        scrub_line=$(zpool status "$pool" 2>/dev/null | grep -A1 "scan:" | tail -1 || true)
        if [ -n "$scrub_line" ]; then
            # Extract errors (field after "with 0 errors")
            scrub_errors=$(echo "$scrub_line" | grep -oP 'with \K\d+' || echo "0")
            # Extract scrub completion time
            scrub_date=$(echo "$scrub_line" | grep -oP 'at \K.+' || echo "")
            if [ -n "$scrub_date" ]; then
                scrub_ts=$(date -d "$scrub_date" +%s 2>/dev/null || echo "0")
            fi
        fi
    fi
    printf 'sis_zfs_pool_scrub_errors{pool="%s"} %d\n' "$pool" "$scrub_errors" >> "$TMPFILE"
    printf 'sis_zfs_pool_scrub_timestamp{pool="%s"} %d\n' "$pool" "$scrub_ts" >> "$TMPFILE"
done

# Atomic write (node-exporter reads partial files during collection)
mv "$TMPFILE" "$TEXTFILE"
chmod 644 "$TEXTFILE"
