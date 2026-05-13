#!/bin/sh
# ZFS Pool Metrics Collector
# ==========================
# Collects ZFS pool health, capacity, and scrub status for Prometheus.
# Outputs metrics in Prometheus textfile collector format.
#
# Setup (TrueNAS SCALE):
#   1. Copy to ~truenas_admin/zfs-metrics.sh
#   2. chmod +x ~/zfs-metrics.sh
#   3. Add root cron (textfile dir is owned by root):
#      echo "*/5 * * * * truenas_admin PATH=/usr/sbin:/usr/bin:/sbin:/bin /home/truenas_admin/zfs-metrics.sh" | sudo tee /etc/cron.d/zfs-metrics
#   4. Ensure TEXTFILE_DIR matches node-exporter textfile collector mount
#
# Tested on: TrueNAS SCALE (ZFS on Linux)
set -eu

TEXTFILE_DIR="${TEXTFILE_DIR:-/mnt/pool_HDD_x2/tank/datasources/sis/appdata/monitoring/textfile-collector}"
TEXTFILE="$TEXTFILE_DIR/zfs.prom"
TMPFILE=$(mktemp)
ZPOOLOUT=$(mktemp)
trap 'rm -f "$TMPFILE" "$ZPOOLOUT"' EXIT

# Headers
{
  printf '# HELP sis_zfs_pool_health ZFS pool health status (1=online, 0=degraded/faulted)\n'
  printf '# TYPE sis_zfs_pool_health gauge\n'
  printf '# HELP sis_zfs_pool_capacity_bytes ZFS pool total capacity in bytes\n'
  printf '# TYPE sis_zfs_pool_capacity_bytes gauge\n'
  printf '# HELP sis_zfs_pool_used_bytes ZFS pool used space in bytes\n'
  printf '# TYPE sis_zfs_pool_used_bytes gauge\n'
  printf '# HELP sis_zfs_pool_available_bytes ZFS pool available space in bytes\n'
  printf '# TYPE sis_zfs_pool_available_bytes gauge\n'
  printf '# HELP sis_zfs_pool_capacity_pct ZFS pool capacity usage percentage\n'
  printf '# TYPE sis_zfs_pool_capacity_pct gauge\n'
  printf '# HELP sis_zfs_pool_scrub_errors ZFS pool scrub error count (0 = clean)\n'
  printf '# TYPE sis_zfs_pool_scrub_errors gauge\n'
  printf '# HELP sis_zfs_pool_scrub_timestamp ZFS pool last scrub completion as Unix timestamp\n'
  printf '# TYPE sis_zfs_pool_scrub_timestamp gauge\n'
} > "$TMPFILE"

# Collect zpool output to temp file (avoids pipeline subshell issue)
zpool list -H -p -o name,health,size,allocated,free > "$ZPOOLOUT" 2>/dev/null || true

while IFS='	' read -r pool health size allocated free; do
  # Health: online=1, degraded=0, faulted=0
  if [ "$health" = "ONLINE" ]; then
    health_val=1
  else
    health_val=0
  fi

  {
    printf 'sis_zfs_pool_health{pool="%s"} %d\n' "$pool" "$health_val"
    printf 'sis_zfs_pool_capacity_bytes{pool="%s"} %d\n' "$pool" "$size"
    printf 'sis_zfs_pool_used_bytes{pool="%s"} %d\n' "$pool" "$allocated"
    printf 'sis_zfs_pool_available_bytes{pool="%s"} %d\n' "$pool" "$free"

    # Capacity percentage
    if [ "$size" -gt 0 ]; then
      pct=$((allocated * 100 / size))
    else
      pct=0
    fi
    printf 'sis_zfs_pool_capacity_pct{pool="%s"} %d\n' "$pool" "$pct"

    # Scrub status
    scrub_errors=0
    scrub_ts=0
    scrub_line=$(zpool status "$pool" 2>/dev/null | grep -A1 "scan:" | tail -1 || true)
    if [ -n "$scrub_line" ]; then
      scrub_errors=$(echo "$scrub_line" | grep -oP 'with \K\d+' 2>/dev/null || echo "0")
      scrub_date=$(echo "$scrub_line" | grep -oP 'at \K.+' 2>/dev/null || echo "")
      if [ -n "$scrub_date" ]; then
        scrub_ts=$(date -d "$scrub_date" +%s 2>/dev/null || echo "0")
      fi
    fi
    printf 'sis_zfs_pool_scrub_errors{pool="%s"} %d\n' "$pool" "$scrub_errors"
    printf 'sis_zfs_pool_scrub_timestamp{pool="%s"} %d\n' "$pool" "$scrub_ts"
  } >> "$TMPFILE"
done < "$ZPOOLOUT"

# Atomic write (node-exporter reads partial files during collection)
mv "$TMPFILE" "$TEXTFILE"
chmod 644 "$TEXTFILE"
