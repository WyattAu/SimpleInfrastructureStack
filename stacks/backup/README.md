# Backup Stack

## Overview

Automated daily backups using [Restic](https://restic.net/) with local storage on the data pool and optional offsite sync to Backblaze B2.

## Current Configuration

| Setting | Value |
|---------|-------|
| Schedule | Daily at 02:00 UTC |
| Local repository | `/mnt/pool_HDD_x2/tank/datasources/sis/backups/restic-repo` |
| Snapshot count | 3 (auto-retained per policy) |
| Backup size | ~30 GB per snapshot |
| Daily growth | ~170 MB |
| Compression ratio | 1.66x |
| Restore verification | Automatic (after each backup) |

## Retention Policy

| Period | Count |
|--------|-------|
| Hourly | 24 |
| Daily | 7 |
| Weekly | 4 |
| Monthly | 6 |
| Yearly | 3 |

## How It Works

1. **backup-cron-trigger** (Alpine + docker-cli) runs `crond` and executes `run-backup.sh` at 02:00 UTC
2. `run-backup.sh` uses `docker exec` to run restic commands inside **backup-restic**
3. Restic backs up `${DATA_BASE_PATH}` (all app data) to the local repository
4. After backup, retention policy prunes old snapshots
5. Repository health is checked (`restic check`)
6. A single file is restored to verify backup integrity
7. If `OFFSITE_REPO` is set, all snapshots are synced to the remote repository

## Enabling Offsite Backup (Backblaze B2)

### Step 1: Create a B2 Bucket

1. Go to https://secure.backblaze.com/b2_buckets.htm
2. Click "Create a Bucket"
3. Bucket name: `sis-infra-backup` (or any name you prefer)
4. File Lifecycle Rules: Keep all versions (default)
5. Click "Create Bucket"

### Step 2: Create Application Keys

1. Go to https://secure.backblaze.com/app_keys.htm
2. Click "Add Application Key"
3. Key Name: `sis-infra-restic`
4. Allow access to Bucket(s): `sis-infra-backup`
5. Type of Access: Read and Write
6. Click "Create Key"
7. **Save the keyID and keyName** (applicationKey is only shown once!)

### Step 3: Add Credentials to Secrets

Decrypt, edit, and re-encrypt the backup secrets:

```bash
# Decrypt
sops -d --input-type dotenv --output-type dotenv secrets/backup.env.encrypted > /tmp/backup.decrypted

# Edit — add these 3 lines:
# OFFSITE_REPO=s3:https://s3.us-west-004.backblazeb2.com/sis-infra-backup/repo
# OFFSITE_AWS_KEY=<your-keyId>
# OFFSITE_AWS_SECRET=<your-applicationKey>

# Re-encrypt
sops -e --input-type dotenv --output-type dotenv \
  --filename-override secrets/backup.env.encrypted \
  --config .sops.yaml /tmp/backup.decrypted > secrets/backup.env.encrypted
rm /tmp/backup.decrypted
```

### Step 4: Deploy

Commit and push the changes. The next daily backup at 02:00 UTC will automatically sync to B2.

### Step 5: Verify Offsite

After the first backup with offsite enabled, check the logs:

```bash
ssh truenas_admin@192.168.1.3 "sudo docker logs backup-cron-trigger 2>&1 | grep offsite"
```

You should see: `Syncing to offsite repository: s3:...` and `Offsite sync completed.`

### B2 Storage Cost Estimate

| Item | Value |
|------|-------|
| Data stored | ~30 GB (first snapshot), ~170 MB/day delta |
| B2 storage cost | $0.006/GB/month = ~$0.18/month |
| B2 download cost | $0.01/GB (Class B transactions only) |
| B2 transaction cost | ~$0.004/10K transactions (negligible) |
| **Estimated monthly cost** | **< $1/month** |

## Manual Operations

### Check backup status
```bash
sudo docker exec backup-restic restic snapshots
sudo docker exec backup-restic restic stats --mode raw-data
```

### Restore a specific file
```bash
sudo docker exec backup-restic restic restore latest --target /tmp/restore --include "/data/<path>"
```

### Restore everything (disaster recovery)
```bash
sudo docker exec backup-restic restic restore latest --target /mnt/pool_HDD_x2/tank/datasources/sis/
```

### Force a backup now
```bash
sudo docker exec backup-cron-trigger /scripts/run-backup.sh
```

### Check repository health
```bash
sudo docker exec backup-restic restic check
```
