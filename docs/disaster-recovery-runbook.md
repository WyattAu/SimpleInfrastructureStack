# Disaster Recovery Runbook

## Overview

This document describes how to recover the entire SimpleInfrastructureStack from scratch
using only the Git repository, the age encryption key, and the Backblaze B2 backup.
No local backups or configuration files are required — everything is reproducible from source.

## Recovery Scenarios

| Scenario | Approach | Estimated Time |
|----------|----------|---------------|
| Container crash | Ansible deploy (automatic) | 5 min |
| TrueNAS pool corruption | Restore from B2 onto new TrueNAS | 2-4 hours |
| Full server replacement | Fresh TrueNAS + restore from B2 | 3-6 hours |
| Accidental data deletion | Point-in-time Restic restore | 30 min |
| Compromised secrets | Rotate all secrets + redeploy | 1-2 hours |

---

## Prerequisites (Save These Somewhere Safe)

You MUST have these to recover:

1. **Age encryption key** — Used by SOPS to encrypt/decrypt secrets
   - Location: `~/.config/sops/age/keys.txt` (on local machine AND on server at `/root/.config/sops/age/keys.txt`)
   - Public key: `age13kqew6kglat9hlswcstcxpdtvfh8v7pckr0wt3qvqkn7u2cj3e6qnm03uc`
   - **If lost: ALL secrets are unrecoverable.** Store a backup offsite (e.g., printed QR code in a physical safe).

2. **GitHub credentials** — Access to the repository
   - Repository: `github.com/WyattAu/SimpleInfrastructureStack`
   - SSH key or personal access token with repo access

3. **Backblaze B2 credentials** — Access to offsite backups
   - Stored in `secrets/backup.env.encrypted` (encrypted with age key)
   - B2 bucket name, key ID, application key

4. **Cloudflare API token** — Used by Terraform for DNS management
   - Stored in `secrets/proxy.env.encrypted`
   - **Alternative:** Login to Cloudflare dashboard and create a new token

5. **Forgejo admin token** — Used by Terraform for org/team management
   - Stored in `.forgejo_token` (committed to git, non-sensitive)
   - **Alternative:** Generate a new token via `gitea admin user generate-access-token`

---

## Scenario 1: Container Crash / Deploy Failure

The deploy pipeline includes automatic rollback. If Ansible fails, it resets to the previous commit and redeploys.

### Manual recovery:
```bash
# SSH to server
ssh truenas_admin@192.168.1.3

# Check deploy log
sudo tail -100 /var/log/infra-deploy.log

# Manual rollback to previous commit
cd /mnt/pool_HDD_x2/infra/stacks
git log --oneline -5
git reset --hard <previous-sha>
sudo docker compose -f stacks/monitoring/docker-compose.yml up -d
# ... repeat for affected stacks

# Or trigger a full redeploy via webhook
curl -X POST https://deploy.wyattau.com/hooks/deploy \
  -H "X-Hub-Signature-256: <hmac>" \
  -d '{}'
```

---

## Scenario 2: Restore Application Data from Backup

Use Restic to restore specific files or entire directories from a snapshot.

### List available snapshots:
```bash
# SSH to server, enter backup container
ssh truenas_admin@192.168.1.3
sudo docker exec -it backup-restic sh

# List snapshots
restic -r /backup/repo snapshots
restic -r /backup/repo snapshots --tag offsite  # B2 snapshots
```

### Restore a specific file:
```bash
sudo docker exec -it backup-restic sh
restic -r /backup/repo restore latest --target /tmp/restore --include "/data/iam/keycloak/*"
sudo cp /tmp/restore/data/iam/keycloak/<file> /mnt/pool_HDD_x2/tank/datasources/sis/appdata/iam/keycloak/
```

### Restore an entire stack's data:
```bash
sudo docker exec -it backup-restic sh
restic -r /backup/repo restore latest --target /tmp/restore --include "/data/collaboration/*"
sudo systemctl stop collaboration-*  # or docker compose down
sudo cp -a /tmp/restore/data/collaboration/* /mnt/pool_HDD_x2/tank/datasources/sis/appdata/collaboration/
```

### Restore from B2 (offsite):
```bash
sudo docker exec -it backup-restic sh
export B2_ACCOUNT_ID="<from backup.env.encrypted>"
export B2_ACCOUNT_KEY="<from backup.env.encrypted>"
export RESTIC_PASSWORD="<from backup.env.encrypted>"
restic -r b2:<bucket-name>:repo snapshots
restic -r b2:<bucket-name>:repo restore latest --target /tmp/restore
```

---

## Scenario 3: Full Server Recovery (TrueNAS Replacement)

### Phase 1: Fresh TrueNAS Setup (30 min)

1. Install TrueNAS SCALE on new hardware
2. Create pool: `pool_HDD_x2` (ZFS mirror, same name as original)
3. Create dataset: `tank/datasources/sis` (for app data)
4. Create dataset: `tank/datasources/sis/appdata` (for container data)
5. Create dataset: `tank/datasources/sis/backups` (for local backup cache)
6. Enable SSH service
7. Create user `truenas_admin` with sudo access

### Phase 2: Install Prerequisites (15 min)

```bash
# Install Docker Compose v2
sudo mkdir -p /mnt/pool_HDD_x2/infra/bin
curl -sLo /tmp/docker-compose \
  https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64
sudo chmod +x /tmp/docker-compose
sudo mv /tmp/docker-compose /mnt/pool_HDD_x2/infra/bin/docker-compose

# Install Terraform
curl -sLo /tmp/terraform.zip \
  https://releases.hashicorp.com/terraform/1.10.5/terraform_1.10.5_linux_amd64.zip
sudo unzip -o /tmp/terraform.zip -d /mnt/pool_HDD_x2/infra/bin/

# Install Ansible
sudo apt-get update && sudo apt-get install -y ansible

# Install SOPS + age
curl -sLo /usr/local/bin/sops https://github.com/getsops/sops/releases/download/v3.9.0/sops-v3.9.0.linux.amd64
curl -sLo /usr/local/bin/age-keygen https://dl.filippo.io/age/latest?for=linux/amd64
sudo chmod +x /usr/local/bin/sops /usr/local/bin/age-keygen
```

### Phase 3: Restore Age Key (2 min)

```bash
# Copy your age key to the server
mkdir -p ~/.config/sops/age
# Paste the private key content (starts with AGE_SECRET_KEY_)
nano ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt

# Also copy to root for webhook container access
sudo mkdir -p /root/.config/sops/age
sudo cp ~/.config/sops/age/keys.txt /root/.config/sops/age/keys.txt
sudo chmod 600 /root/.config/sops/age/keys.txt
```

### Phase 4: Clone Repository (2 min)

```bash
mkdir -p /mnt/pool_HDD_x2/infra/stacks
cd /mnt/pool_HDD_x2/infra/stacks
git clone git@github.com:WyattAu/SimpleInfrastructureStack.git .
```

### Phase 5: Restore Application Data from B2 (30-60 min)

```bash
cd /mnt/pool_HDD_x2/infra/stacks

# Decrypt backup secrets
sops -d --input-type dotenv --output-type dotenv \
  secrets/backup.env.encrypted > /tmp/backup.env

# Source the credentials
source /tmp/backup.env
rm /tmp/backup.env

# Initialize local Restic repo and restore from B2
export RESTIC_REPOSITORY=/mnt/pool_HDD_x2/tank/datasources/sis/backups/restic-repo
export RESTIC_PASSWORD="$BACKUP_RESTIC_PASSWORD"
export AWS_ACCESS_KEY_ID="$OFFSITE_AWS_KEY"
export AWS_SECRET_ACCESS_KEY="$OFFSITE_AWS_SECRET"

restic init
restic copy b2:"$B2_BUCKET":repo:latest /

# Restore data to appdata directory
restic restore latest --target /mnt/pool_HDD_x2/tank/datasources/sis/appdata

# Clean up
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```

### Phase 6: Create Infrastructure Directories (5 min)

```bash
# Create data directories for each stack
for stack in proxy iam monitoring operations collaboration storage \
             accounting utility backup vaultwarden rss photos documents vpn updater; do
  mkdir -p /mnt/pool_HDD_x2/tank/datasources/sis/appdata/$stack
done

# Move restored data into place (if restored to flat directory)
# The restore target should match the backup source paths
```

### Phase 7: Deploy All Stacks (15-30 min)

```bash
cd /mnt/pool_HDD_x2/infra/stacks

# Decrypt all secrets
for f in secrets/*.env.encrypted; do
  sops -d --input-type dotenv --output-type dotenv \
    --config .sops.yaml \
    --output .secrets.tmp/$(basename $f .env.encrypted).env \
    "$f"
done

# Deploy all stacks
for stack in tunnel proxy iam monitoring operations collaboration \
             storage accounting utility backup vaultwarden rss photos \
             documents vpn updater; do
  docker compose -f stacks/$stack/docker-compose.yml --env-file .secrets.tmp/${stack}.env up -d
done

# Clean up decrypted secrets
rm -rf .secrets.tmp/*
```

### Phase 8: Verify (10 min)

```bash
# Check all containers are running
docker ps --format "table {{.Names}}\t{{.Status}}"

# Check critical services
curl -sf https://auth.wyattau.com/realms/company-realm && echo "Keycloak: OK"
curl -sf https://forgejo.wyattau.com/ && echo "Forgejo: OK"
curl -sf https://grafana.wyattau.com/api/health && echo "Grafana: OK"
```

### Phase 9: Restore Terraform State (5 min)

The Terraform state is backed up in the Restic backup under `/terraform/`.
After restoring application data, the state file should be at:

```
/mnt/pool_HDD_x2/infra/stacks/terraform/terraform.tfstate
```

Verify:
```bash
cd /mnt/pool_HDD_x2/infra/stacks/terraform
/mnt/pool_HDD_x2/infra/bin/terraform init
/mnt/pool_HDD_x2/infra/bin/terraform plan
# Should show "No changes" if DNS/identity state is intact
```

### Phase 10: Restore Monitoring Data (Optional)

Prometheus TSDB and Loki data are backed up but large. Restoring them gives
you historical metrics and logs but is not critical for operations.

```bash
# If you want historical metrics
restic restore latest --target /tmp/monitoring-restore \
  --include "/data/monitoring/*"
cp -a /tmp/monitoring-restore/data/monitoring/* \
  /mnt/pool_HDD_x2/tank/datasources/sis/appdata/monitoring/
```

---

## Scenario 4: Compromised Secrets

If secrets are leaked or a container is compromised:

### 1. Rotate Cloudflare API token
```bash
# Cloudflare Dashboard → My Profile → API Tokens → Create new token
# Update secrets/proxy.env.encrypted
sops -e --input-type dotenv --output-type dotenv \
  --config .sops.yaml \
  secrets/proxy.env.encrypted
# Edit the CF_API_TOKEN value
```

### 2. Rotate Keycloak client secrets
```bash
# Keycloak Admin Console → Clients → <client> → Credentials → Regenerate
# Update the relevant .env.encrypted file
```

### 3. Rotate Forgejo token
```bash
sudo docker exec -u git operations-forgejo \
  gitea -c /data/gitea/conf/app.ini \
  admin user generate-access-token -u wyatt_admin --scopes all -t terraform
# Update .forgejo_token
```

### 4. Rotate database passwords
```bash
# Connect to each PostgreSQL container and alter the user password
sudo docker exec -it iam-postgres psql -U keycloak -d keycloak \
  -c "ALTER USER keycloak WITH PASSWORD 'new_password';"
# Update the corresponding .env.encrypted file
# Update postgres-exporter .pgpass file (re-deploy will regenerate it)
```

### 5. Rotate webhook shared secret
```bash
# Generate a new random secret
openssl rand -hex 32
# Update WEBHOOK_SECRET in webhook docker-compose environment
# Update GitHub Actions secret: repository Settings → Secrets → WEBHOOK_SHARED_SECRET
```

### 6. Rotate age key (last resort)
```bash
# This requires re-encrypting ALL secret files
age-keygen -o ~/.config/sops/age/keys.txt
# Get the new public key from the output
# Update .sops.yaml with the new public key
# Re-encrypt all secret files:
for f in secrets/*.env.encrypted; do
  sops -e --input-type dotenv --output-type dotenv \
    --config .sops.yaml \
    --input <(sops -d --input-type dotenv --output-type dotenv "$f") \
    "$f"
done
# Copy new key to server
```

---

## Scenario 5: Cloudflare Tunnel Failure

The Cloudflare Tunnel (`infra-tunnel`) is deployed first in the stack order because
the deploy webhook routes through it. If the tunnel breaks:

```bash
# Check tunnel status
sudo docker logs monitoring-tunnel --tail 50

# Restart tunnel
cd /mnt/pool_HDD_x2/infra/stacks
sudo docker compose -f stacks/tunnel/docker-compose.yml restart

# If tunnel token is invalid, re-authenticate:
# cloudflared tunnel login
# cloudflared tunnel run <tunnel-id>
```

---

## Backup Verification Schedule

The backup system includes automated verification:

| Check | Frequency | Location |
|-------|-----------|----------|
| `restic check` | Daily (02:00 UTC) | `run-backup.sh` |
| Restore test (single file) | Monthly (03:00, 1st of month) | `run-restore-test.sh` |
| Offsite sync to B2 | Daily (after backup) | `run-backup.sh` |

### Manual full restore test (recommended quarterly):

1. Spin up a test VM or TrueNAS instance
2. Follow Scenario 3 (Full Server Recovery) using B2 as the source
3. Verify all 50 containers start and pass health checks
4. Verify SSO login works via Keycloak
5. Document any issues found

---

## Important Notes

- **`/home` is `noexec`, `/opt` is `ro`** on TrueNAS. All binaries go in `/mnt/pool_HDD_x2/infra/bin/`.
- **Docker data root** is on the ZFS pool, not in `/var/lib/docker`.
- **Terraform state** is backed up via Restic. The `.tfstate` file is gitignored.
- **Secrets are encrypted** with age (SOPS). The age key is the single point of failure.
- **The deploy webhook** is the primary deployment mechanism. It handles git pull + Ansible playbook.
- **Ansible runs as root** on localhost. All paths use `sudo`.
