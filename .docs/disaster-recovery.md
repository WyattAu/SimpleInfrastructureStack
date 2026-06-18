# Disaster Recovery Procedure

## Overview

- **RPO**: 1 day (3AM daily backup)
- **RTO**: 1 hour (full stack restore from restic)
- **Backup locations**: Local restic repo + B2 offsite sync
- **Infrastructure**: TrueNAS Scale, Docker Compose, Ansible automation

## Backup Architecture

```
Local: /mnt/pool_HDD_x2/tank/datasources/sis/backups/restic-repo-new
Offsite: B2 bucket SisInfraBackup (eu-central-003)
Cron: 3:00 AM daily via TrueNAS middleware
Script: /mnt/pool_HDD_x2/tank/datasources/sis/backups/backup.sh
```

### What is Backed Up
- All container data (appdata/)
- PostgreSQL dumps (each stacks DB)
- Configuration files (compose, env, configs)
- Keycloak realm export

### What is NOT Backed Up
- Container images (pull from registry)
- EIR images (rebuild from CI)
- TrueNAS system config (separate backup)

## Restore Procedure

### Step 1: Access TrueNAS
```
ssh truenas_admin@192.168.1.3
```

### Step 2: List Available Snapshots
```
RESTIC_PASSWORD='Ki/+lLYMLu0/0sCBsKpxpISjOY2tBjcIBaFL31Moi+4=' \
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
AWS_ACCESS_KEY_ID=003f3a2e96de77b0000000001 \
AWS_SECRET_ACCESS_KEY='K003+fw0lRndYztZMFLM+lyplqfsLL0' \
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

- Uptime Kuma: http://kuma.wyattau.com
- Grafana: http://traefik.wyattau.com/grafana
- Alerts: Alertmanager to ntfy.sh
- Backup metrics: /mnt/.../backups/backup.prom

## Testing

- Monthly: Automated restore test in backup.sh
- Quarterly: Manual full DR drill
