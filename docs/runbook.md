# SimpleInfrastructureStack — Operational Runbook

> TrueNAS SCALE at 192.168.1.3 · Docker Compose · Ansible · GitHub Actions

## Architecture Overview

```
GitHub (main) ──push──► GitHub Actions (validate)
                        │
                        ├─ merge to main
                        │
                        ▼
Cloudflare Tunnel ──► deploy.wyattau.com ──► infra-webhook:9001
                                               │
                                               ▼
                                         Ansible (site.yml)
                                               │
                                     ┌──────────┼──────────┐
                                     ▼          ▼          ▼
                                   SOPS      Templates  Compose
                                   decrypt   expand     up -d
                                     │          │          │
                                     ▼          ▼          ▼
                               .secrets.tmp/   Jinja2   16 stacks
                               (cleaned up)             │
                                                        ▼
                                                   Health checks
                                                       │
                                                  ┌────┴────┐
                                                  ▼         ▼
                                               Success   Rollback
```

### Stack Map

| Stack | Services | Network | Purpose |
|-------|----------|---------|---------|
| tunnel | cloudflared | host | Cloudflare Tunnel (independent) |
| proxy | traefik, oauth2-proxy, socket-proxy, ddns, well-known | traefik_net, backend_net | Reverse proxy + auth |
| iam | keycloak, postgres | backend_net | Identity (Keycloak) |
| monitoring | prometheus, grafana, loki, promtail, kuma, cadvisor, node-exporter, alertmanager | traefik_net, backend_net | Observability |
| operations | forgejo, forgejo-runner, postgres | traefik_net, backend_net | Git hosting + CI |
| collaboration | synapse, element, hookshot, postgres | traefik_net, backend_net | Matrix chat + GitHub bridge |
| storage | ocis, collabora | traefik_net, backend_net | Files + office |
| accounting | akaunting, mariadb | backend_net | Accounting |
| utility | homepage | traefik_net | Dashboard |
| backup | restic, cron-trigger | none | Backups (local + B2) |
| vaultwarden | vaultwarden | traefik_net | Password manager |
| rss | freshrss, postgres | traefik_net, backend_net | RSS feed reader |
| photos | immich (server + ml), postgres, valkey | traefik_net, backend_net | Photo management |
| documents | paperless-ngx, postgres, redis | traefik_net, backend_net | Document management |
| vpn | wireguard | host | VPN access |
| updater | watchtower | none | Update notifications |

### DNS Records

| Subdomain | Service | Auth |
|-----------|---------|------|
| traefik.wyattau.com | Traefik dashboard | OAuth2 |
| auth.wyattau.com | Keycloak | Public |
| forgejo.wyattau.com | Forgejo | OAuth2 |
| registry-forgejo.wyattau.com | Forgejo container registry | Token |
| grafana.wyattau.com | Grafana | OIDC (Keycloak) |
| prometheus.wyattau.com | Prometheus | OAuth2 |
| kuma.wyattau.com | Uptime Kuma | OAuth2 |
| homepage.wyattau.com | Homepage | OAuth2 |
| element.wyattau.com | Element Web | Public |
| matrix.wyattau.com | Synapse (CS API) | Public |
| ocis.wyattau.com | ownCloud Infinite Scale | Public |
| akaunting.wyattau.com | Akaunting | Public |
| vault.wyattau.com | Vaultwarden | Built-in (Bitwarden) |
| rss.wyattau.com | FreshRSS | Public |
| photos.wyattau.com | Immich | Public |
| docs.wyattau.com | Paperless-ngx | Public |
| hookshot.wyattau.com | Matrix Hookshot | N/A (internal) |
| collabora.wyattau.com | Collabora Online | Public |
| ssh.wyattau.com | SSH via tunnel | Key |
| deploy.wyattau.com | Webhook via tunnel | HMAC |

## Common Operations

### Trigger a Deploy

```bash
# Empty body deploy (triggers latest main)
curl -s -o /dev/null -w "%{http_code}" -X POST \
  "https://deploy.wyattau.com/hooks/deploy" \
  -H "X-Hub-Signature-256: sha256=$(echo -n '' | openssl dgst -sha256 -hmac '<WEBHOOK_SECRET>' | awk '{print $2}')"
```

### Check Deploy Log

```bash
ssh -i ~/.ssh/id_ed25519 truenas_admin@192.168.1.3 "tail -50 /var/log/infra-deploy.log"
```

### Check Container Health

```bash
ssh -i ~/.ssh/id_ed25519 truenas_admin@192.168.1.3 "sudo docker ps --format 'table {{.Names}}\t{{.Status}}' | sort"
```

### Check Prometheus Alerts

```bash
# From inside any backend_net container (e.g., operations-forgejo)
sudo docker exec operations-forgejo curl -s \
  'http://monitoring-prometheus:9090/api/v1/query?query=ALERTS%7Balertstate%3D%22firing%22%7D'
```

### Decrypt Secrets Locally

```bash
sops -d --input-type dotenv --output-type dotenv secrets/<stack>.env.encrypted
```

### Re-encrypt Secrets

```bash
# Edit the plaintext file, then:
cp plaintext.env secrets/<stack>.env.encrypted
sops --encrypt --input-type dotenv --output-type dotenv --in-place secrets/<stack>.env.encrypted
```

### Restart a Single Container

```bash
ssh -i ~/.ssh/id_ed25519 truenas_admin@192.168.1.3 "sudo docker restart <container-name>"
```

### View Container Logs

```bash
ssh -i ~/.ssh/id_ed25519 truenas_admin@192.168.1.3 "sudo docker logs --tail 100 <container-name>"
```

### SSH via Tunnel

```bash
ssh -o ProxyCommand="cloudflared access ssh --hostname ssh.wyattau.com" truenas_admin@192.168.1.3
```

## Secrets Management

### Encryption

All secrets are encrypted with [SOPS](https://github.com/getsops/sops) using [age](https://github.com/FiloSottile/age).

- **Public key:** `age13kqew6kglat9hlswcstcxpdtvfh8v7pckr0wt3qvqkn7u2cj3e6qnm03uc`
- **Private key:** `~/.config/sops/age/keys.txt` (local + inside `infra-webhook` container)
- **Config:** `.sops.yaml` — rules for `secrets/*.env.encrypted`

### Secret Files

| File | Contents |
|------|----------|
| `secrets/proxy.env.encrypted` | CF API token, OAuth2 client secret, cookie secret |
| `secrets/iam.env.encrypted` | Keycloak DB password, admin password, OIDC secrets, SMTP |
| `secrets/monitoring.env.encrypted` | Grafana admin password, OIDC client, ntfy topic, SMTP |
| `secrets/operations.env.encrypted` | Forgejo DB password, OIDC client secret, SMTP |
| `secrets/collaboration.env.encrypted` | Synapse DB password, registration secret, SMTP, GitHub app |
| `secrets/storage.env.encrypted` | OCIS admin password, JWT secret |
| `secrets/accounting.env.encrypted` | Akaunting DB password |
| `secrets/backup.env.encrypted` | Restic password, B2 keys |
| `secrets/tunnel.env.encrypted` | Empty (no secrets needed) |
| `secrets/vaultwarden.env.encrypted` | Admin token |
| `secrets/rss.env.encrypted` | FreshRSS DB password |
| `secrets/photos.env.encrypted` | Immich DB password |
| `secrets/documents.env.encrypted` | Paperless DB password, secret key |
| `secrets/vpn.env.encrypted` | Empty (no secrets needed) |
| `secrets/updater.env.encrypted` | ntfy URL, topic |

### Deploy-Time Flow

1. SOPS decrypts all `*.env.encrypted` → `.secrets.tmp/*.env`
2. Ansible loads them as variables via Python dotenv→YAML converter
3. Jinja2 templates expanded with secret values
4. Docker Compose uses `--env-file .secrets.tmp/<stack>.env`
5. All `.secrets.tmp/` files deleted in `post_tasks`

## Backup & Recovery

### RTO / RPO

| Metric | Target |
|--------|--------|
| **RPO** (Recovery Point Objective) | 24 hours (daily backup at 02:00 UTC) |
| **RTO** (Recovery Time Objective) | 2 hours (ansible redeploy + DB restore) |

### What's Backed Up

Local backup (Restic) → `/mnt/pool_HDD_x2/tank/datasources/sis/backups/restic-repo/`
- All app data: `/mnt/pool_HDD_x2/tank/datasources/sis/appdata/`
- Retention: 24 hourly, 7 daily, 4 weekly, 6 monthly, 3 yearly

Offsite backup (B2) → `s3:.../SisInfraBackup/repo`
- Synced after each local backup
- Cost: ~$0.12/month for 30GB
- Same retention policy as local

### What's NOT Backed Up (Recreated from Git)

- Docker images (pulled from registries)
- Compose files, Ansible playbooks, Prometheus rules (all in git)
- Keycloak realm config (export via admin API if needed)
- Traefik ACME certs (auto-renewed via DNS-01 challenge)

### Run a Manual Backup

```bash
# Inside the backup-restic container
sudo docker exec backup-restic restic -r /restic-repo backup /data --tag manual
sudo docker exec backup-restic restic -r /restic-repo check
```

### Restore from Backup

```bash
# 1. List snapshots
sudo docker exec backup-restic restic -r /restic-repo snapshots

# 2. Restore specific snapshot (example: latest)
sudo docker exec backup-restic restic -r /restic-repo restore latest --target /tmp/restore

# 3. For database restores, stop the service first:
sudo docker stop <service-container>
# Copy restored DB files to the data directory
# Restart the service
```

### Keycloak Realm Export

```bash
# Export realm config (for backup or migration)
sudo docker exec iam-keycloak /opt/keycloak/bin/kc.sh export --realm company-realm --file /tmp/realm-export.json

# Copy out
sudo docker cp iam-keycloak:/tmp/realm-export.json /tmp/realm-export.json
```

### Forgejo Database Restore

```bash
# 1. Stop Forgejo
sudo docker stop operations-forgejo

# 2. Restore from Restic (find the right snapshot first)
sudo docker exec backup-restic restic -r /restic-repo dump latest --path /data/operations/postgres-forgejo --archive /tmp/forgejo-db.dump

# 3. Restore into PostgreSQL
sudo docker exec -i operations-postgres-forgejo pg_restore -U forgejo -d forgejo --clean --if-exists < /tmp/forgejo-db.dump

# 4. Restart Forgejo
sudo docker start operations-forgejo
```

## Monitoring

### Alert Routing

| Severity | Channel | ntfy Topic |
|----------|---------|------------|
| critical | ntfy push (high priority) | `wyattau-infra-...-critical` |
| warning | ntfy push (normal) | `wyattau-infra-...` |

### Key Dashboards

- **Grafana:** https://grafana.wyattau.com (Keycloak OIDC login)
- **Uptime Kuma:** https://kuma.wyattau.com (Keycloak OAuth2 login)
- **Prometheus:** https://prometheus.wyattau.com (Keycloak OAuth2 login)
- **Traefik:** https://traefik.wyattau.com (Keycloak OAuth2 login)

### SMTP Email

| Service | Config Method | Status |
|---------|--------------|--------|
| Forgejo | `FORGEJO__mailer__*` env vars | Active |
| Keycloak | Realm `smtpServer` via admin API | Active |
| Synapse | `homeserver.yaml` `email:` block | Active |

SMTP provider: SMTP2GO (`mail.smtp2go.com:2525`)

## TLS Certificates

- **Issuer:** Let's Encrypt (DNS-01 challenge via Cloudflare)
- **Resolver:** Traefik ACME (`cloudflare` certresolver)
- **Storage:** `/mnt/pool_HDD_x2/tank/datasources/sis/appdata/proxy/letsencrypt/acme.json`
- **Auto-renewal:** Traefik renews at 30 days before expiry
- **Expiry alerting:** Prometheus alert (14d warning, 7d critical)

## CI/CD Pipeline

### GitHub Actions (validate.yml)

Runs on push to `main`/`feature/*` and on PRs:
1. YAML lint (yamllint)
2. Docker Compose validation (all stacks)
3. OPA policy check (security.rego)
4. Ansible syntax check
5. Trivy security scan (Dockerfiles + compose files)

### Renovate Bot

- Schedule: Every Sunday 03:00 UTC
- Auto-merges: Disabled (prevents silent breakage from major image changes)
- Manual review: All Docker image updates
- Config: `renovate.json5`

### Nightly Vulnerability Scan

- Schedule: Daily 04:00 UTC
- Scans all pinned container images for CVEs (HIGH/CRITICAL)
- Config: `.github/workflows/vulnerability-scan.yml`

### Deploy Pipeline

```
git push origin main
  → GitHub Actions validates
  → merge completes
  → Cloudflare Tunnel delivers webhook
  → infra-webhook receives POST
  → deploy.sh runs
    → git fetch + reset --hard origin/main
    → SOPS decrypt all secrets
    → Ansible site.yml
      → git sync, decrypt, expand templates
      → docker compose up -d (16 stacks)
      → bind-mount container restarts
      → health checks (60s timeout × 60 retries)
    → ntfy notification (success/failure)
  → secrets cleaned up
```

## Rollback

Automatic rollback is built into the Ansible `site.yml` rescue block:
1. Git reset to previous SHA (stored before deploy)
2. Re-run `docker compose up` from previous commit
3. Notify via ntfy

Manual rollback:
```bash
# Find the previous good commit
ssh -i ~/.ssh/id_ed25519 truenas_admin@192.168.1.3 \
  "cd /mnt/pool_HDD_x2/infra/stacks && git log --oneline -5"

# Reset and redeploy
ssh -i ~/.ssh/id_ed25519 truenas_admin@192.168.1.3 \
  "cd /mnt/pool_HDD_x2/infra/stacks && git reset --hard <SHA>"

# Trigger deploy
curl -s -o /dev/null -w "%{http_code}" -X POST "https://deploy.wyattau.com/hooks/deploy" \
  -H "X-Hub-Signature-256: sha256=$(echo -n '' | openssl dgst -sha256 -hmac '<WEBHOOK_SECRET>' | awk '{print $2}')"
```

## Troubleshooting

### Container Won't Start

1. Check logs: `sudo docker logs <container-name> --tail 50`
2. Check events: `sudo docker events --since 5m`
3. Check resources: `sudo docker stats --no-stream`
4. Check disk: `df -h` and `zfs list`

### Deploy Fails

1. Check log: `tail -100 /var/log/infra-deploy.log`
2. Check for SOPS issues: Verify age key is accessible
3. Check for compose errors: Run `docker compose config` manually on server
4. Manual redeploy: `sudo docker exec infra-webhook bash /opt/webhook/deploy.sh`

### Health Check Timeout

- Keycloak takes ~3-5 min on first boot (Quarkus augmentation)
- Synapse takes ~1-2 min (database migrations)
- Most other services start in <30s

### OOM Kills

- Check: `sudo docker inspect <container> | grep OOM`
- Fix: Increase memory limit in compose file or reduce workload
- Current swap: 4GB zvol on NVMe SSD (`boot-pool/swap`, swappiness=1)

### High Memory Usage

- Check: `sudo docker stats --no-stream | sort -k4 -h`
- Prometheus: 6GB limit (30d retention)
- Keycloak: 4GB limit
- Forgejo: 4GB limit
- Synapse: 8GB limit

### Lost Webhook Access

If the webhook container is broken, deploy from the server directly:
```bash
ssh -i ~/.ssh/id_ed25519 truenas_admin@192.168.1.3
sudo docker exec infra-webhook bash /opt/webhook/deploy.sh
```

## Network Topology

```
┌─────────────────────────────────────────────────────┐
│  traefik_net (172.16.6.0/24)                        │
│  ── Traefik (443, 80, 8448)                         │
│  ── oauth2-proxy, grafana, forgejo, element, etc.   │
│  ── Cloudflare Tunnel (network_mode: host)           │
└─────────────────────┬───────────────────────────────┘
                      │
┌─────────────────────┴───────────────────────────────┐
│  backend_net (172.16.7.0/24)                        │
│  ── All service containers                          │
│  ── PostgreSQL databases                            │
│  ── Prometheus, Loki, Alertmanager                   │
│  ── Prometheus scrape targets                       │
└─────────────────────────────────────────────────────┘
```

## Hardware

| Component | Detail |
|-----------|--------|
| Host | TrueNAS SCALE |
| OS Drive | boot-pool (ZFS) |
| Data | pool_HDD_x2 (ZFS, 2× HDD mirror) |
| RAM | 16GB (32GB physical, 16GB hardware-reserved by TrueNAS) |
| Swap | 4GB zvol on NVMe SSD (`boot-pool/swap`, swappiness=1) |
| CPU | (check `lscpu`) |

## Calendar

| Event | Date | Action |
|-------|------|--------|
| TLS cert renewal | ~May 24 – Jun 12, 2026 | Automatic (Traefik) |
| TLS cert expiry (earliest) | Jun 23, 2026 | ci.wyattau.com (stale, can ignore) |
| TLS cert expiry (latest) | Jul 12, 2026 | matrix.wyattau.com |
