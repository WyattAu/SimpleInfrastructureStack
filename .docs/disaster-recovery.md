# Disaster Recovery Procedure

## Overview

- **RPO**: 1 day (02:00 daily backup) + offsite sync
- **RTO**: 1 hour (full stack restore from restic)
- **Backup locations**: Local restic repo + B2 offsite sync
- **Infrastructure**: TrueNAS Scale, Docker Compose, Ansible automation
- **Secrets**: All credentials live in SOPS-encrypted `secrets/*.env.encrypted`
  (age key: `~/.config/sops/age/keys.txt` on workstation + TrueNAS root)

## Backup Architecture

```
Local:   /mnt/pool_HDD_x2/tank/datasources/sis/backups/restic-repo-new
Offsite: B2 bucket SisInfraBackup (eu-central-003), s3 endpoint
Backup:  backup-cron-trigger container -> docker exec backup-restic restic
Cron:    02:00 daily backup; 01:30 keycloak export; 03:00 monthly restore test
Script:  stacks/backup/scripts/{backup.sh,run-backup.sh,run-restore-test.sh}
Metrics: appdata/monitoring/textfile-collector/backup.prom
```

### What is Backed Up
- All container data (appdata/), including Minecraft archives
  (appdata/backups/minecraft, written hourly-ish by the CachyOS
  `mc-backup.timer` -> `/usr/local/bin/mc-backup.sh`)
- PostgreSQL dumps (each stack's DB, plus headscale via pg_dumpall)
- Configuration files (compose, env, configs)
- Keycloak realm export

### What is NOT Backed Up
- Container images (pull from registry / rebuild via EIR CI)
- TrueNAS system config (separate backup)

## Restore Procedure

### Step 1: Access TrueNAS
```
ssh truenas_admin@192.168.1.3
```

### Step 2: List Available Snapshots
```
RESTIC_PASSWORD='YOUR_RESTIC_PASSWORD_HERE' \
  restic -r /mnt/pool_HDD_x2/tank/datasources/sis/backups/restic-repo-new \
  snapshots --compact
```

### Step 3: Restore Specific Stack
```
RESTIC_PASSWORD='...' \
  restic -r <repo> restore <SNAPSHOT_ID> --target /path/to/restore
```

### Step 4: Restore From B2 Offsite
```
AWS_ACCESS_KEY_ID=YOUR_AWS_ACCESS_KEY_ID_HERE \
AWS_SECRET_ACCESS_KEY='YOUR_AWS_SECRET_ACCESS_KEY_HERE' \
RESTIC_PASSWORD='...' \
  restic -r s3:https://s3.eu-central-003.backblazeb2.com/SisInfraBackup/repo-new \
  restore <SNAPSHOT_ID> --target /path/to/restore
```

### Step 5: Redeploy Stack
```
cd /mnt/pool_HDD_x2/infra/stacks/stacks/<stack>
docker compose --env-file .env up -d
```

## Common Failure Scenarios

| Scenario | Diagnosis | Fix |
|----------|-----------|-----|
| Container crash-loop | docker logs, docker inspect | Fix issue or recreate |
| Forgejo runner offline | docker ps, docker logs | Restart or re-register |
| Database corruption | Check DB logs | Restore from restic |
| TrueNAS disk failure | zpool status | Replace disk, ZFS rebuilds |
| Full system restore | — | Import pool, clone repo, restore from B2 |

## Monitoring

- Uptime Kuma: https://kuma.wyattau.com
- Grafana: https://grafana.wyattau.com
- Alerts: Alertmanager -> ntfy
- Backup metrics: appdata/monitoring/textfile-collector/backup.prom
  (sis_backup_last_success, sis_backup_offsite_last_success)

## Testing

- Monthly (1st, 03:00): `run-restore-test.sh` inside backup-cron-trigger —
  restores latest snapshot to /tmp and validates key files. NOTE: this
  requires bash in the cron-trigger image (added Sep 2026; before that the
  test silently never ran — `env: can't execute 'bash'`).
- Quarterly: Manual full DR drill

## Known Operational Gotchas

- **Vaultwarden ADMIN_TOKEN**: stored as Argon2 PHC with `$` escaped as
  `$$` in .env — compose interpolates `$VAR`, unescaped `$` yields
  instant 401s on /admin.
- **TrueNAS reboot Docker bug**: CoreDNS can land in the wrong network
  namespace after reboot; `fix-docker-dns.service` runs the repair
  script at boot (`/mnt/pool_HDD_x2/infra/stacks/fix-docker-dns.sh`).
- **TrueNAS + user-defined networks**: Docker embedded DNS (127.0.0.11)
  is unreliable for Go binaries with pure resolvers — services pin
  static IPs / use `extra_hosts` (see vmalert, traefik).
- **B2 offsite**: restic repos use per-repo keys (`restic key add` /
  `key remove` for rotation — no repo migration needed). The B2
  application key itself is rotated in the Backblaze console (needs
  account master key).
