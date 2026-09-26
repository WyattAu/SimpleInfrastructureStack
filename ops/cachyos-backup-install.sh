#!/bin/bash
set -e
mkdir -p /opt/sis-backup
cat > /opt/sis-backup/cachyos-backup.sh << 'BK'
#!/bin/bash
# Nightly CachyOS state backup -> TrueNAS tank (which B2 syncs offsite)
set -e
STAMP=$(date +%Y%m%d)
OUT="/home/wyatt/cachyos-state-$STAMP.tar.gz"
WORK="/home/wyatt/.sis-backup-work"
KEEP=7
rm -rf "$WORK"; mkdir -p "$WORK/opt" "$WORK/etc" "$WORK/docker-volumes" "$WORK/meta"
for d in kp-api homebite-api forgejo-runners tachyon kp-ops; do
  [ -d "/opt/$d" ] && cp -a "/opt/$d" "$WORK/opt/" 2>/dev/null || true
done
for f in /etc/fstab /etc/hostname; do cp -a "$f" "$WORK/etc/" 2>/dev/null || true; done
cp -a /var/lib/docker/volumes "$WORK/docker-volumes/" 2>/dev/null || true
mkdir -p "$WORK/meta"
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' > "$WORK/meta/containers.txt" 2>/dev/null || true
tar czf "$OUT" -C "$WORK" . 2>/dev/null
rm -rf "$WORK"
# push to truenas (root key already authorized)
scp -q "$OUT" truenas_admin@192.168.1.3:/mnt/pool_HDD_x2/tank/datasources/sis/backups/cachyos/
rm -f "$OUT"
# prune old ones on truenas (keep 7)
ssh -o StrictHostKeyChecking=accept-new truenas_admin@192.168.1.3 \
  "cd /mnt/pool_HDD_x2/tank/datasources/sis/backups/cachyos 2>/dev/null && ls -t cachyos-state-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f" 2>/dev/null || true
echo "cachyos backup $STAMP pushed"
BK
chmod +x /opt/sis-backup/cachyos-backup.sh
cat > /etc/systemd/system/sis-cachyos-backup.service << 'UNIT'
[Unit]
Description=SIS CachyOS state backup -> TrueNAS
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/sis-backup/cachyos-backup.sh
TimeoutStartSec=1800
UNIT
cat > /etc/systemd/system/sis-cachyos-backup.timer << 'UNIT'
[Unit]
Description=Nightly CachyOS backup at 04:00

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now sis-cachyos-backup.timer
systemctl list-timers sis-cachyos-backup.timer --no-pager | head -3
