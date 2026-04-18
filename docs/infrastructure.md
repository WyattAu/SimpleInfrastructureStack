# SimpleInfrastructureStack — Infrastructure Documentation

Self-hosted homelab on TrueNAS SCALE (wyattau.com). 50+ containers across 17 stacks,
managed entirely from a single Git repository with automated CI/CD.

---

## Architecture Overview

```
                        Internet
                           |
                    Cloudflare (WAF/DNS/TLS)
                           |
                    Cloudflare Tunnel
                    (ssh/deploy only)
                           |
                    TrueNAS SCALE Host
                    (62.49.93.199)
                           |
              +------------+------------+
              |                         |
         traefik_net                backend_net
         (ingress only)       (inter-container comms)
              |                         |
         Traefik :80/:443       all app containers
         Traefik :8448                |
              |                  data_net
         Public endpoints        (databases only)
```

**3-tier network architecture:**
- `traefik_net` — ingress network. Only containers that serve HTTP/Traefik attach here.
- `backend_net` — application network. Inter-service communication (exporters, metrics, internal APIs).
- `data_net` — database network. PostgreSQL, MariaDB, Redis, Valkey instances only.

**Deployment flow:**
```
GitHub push → validate.yml (CI) → webhook (POST) → deploy.sh
  → ansible-playbook site.yml
    → prepare (git sync + SOPS decrypt)
    → include_vars (load secrets)
    → terraform (DNS/identity/orgs)
    → expand (Jinja2 templates)
    → detect (bind-mount changes)
    → deploy (docker compose up per stack)
    → health (poll all containers)
    → rescue (rollback if failed)
    → cleanup (rm .secrets.tmp/*)
```

---

## Service Inventory

| Subdomain | Container | Image | Port | Stack | Description |
|---|---|---|---|---|---|
| `traefik` | proxy-traefik | traefik | 80, 443, 8448, 8080 | proxy | Reverse proxy + TLS termination |
| — | proxy-socket-proxy | tecnativa/docker-socket-proxy | — | proxy | Docker socket proxy for Traefik |
| — | proxy-oauth2-proxy | quay.io/oauth2-proxy/oauth2-proxy | 4180 | proxy | Keycloak forwardAuth middleware |
| — | proxy-cloudflare-ddns | favonia/cloudflare-ddns | — | proxy | Dynamic DNS updates (*/5 min) |
| — | proxy-well-known-server | nginx | 80 | proxy | Matrix .well-known/server |
| `auth` | iam-keycloak | quay.io/keycloak/keycloak | 8080, 9000 | iam | SSO identity provider |
| — | iam-postgres | postgres | 5432 | iam | Keycloak database |
| `prometheus` | monitoring-prometheus | prom/prometheus | 9090 | monitoring | Metrics collection |
| `grafana` | monitoring-grafana | grafana/grafana | 3000 | monitoring | Dashboards + visualization |
| `kuma` | monitoring-kuma | louislam/uptime-kuma | 3001 | monitoring | Uptime monitoring |
| — | monitoring-loki | grafana/loki | 3100 | monitoring | Log aggregation |
| — | monitoring-promtail | grafana/promtail | — | monitoring | Log shipper |
| — | monitoring-alertmanager | prom/alertmanager | 9093 | monitoring | Alert routing → ntfy |
| — | monitoring-node-exporter | prom/node-exporter | 9100 | monitoring | Host metrics |
| — | monitoring-cadvisor | ghcr.io/google/cadvisor | 8080 | monitoring | Container metrics |
| — | monitoring-postgres-exporter | quay.io/prometheuscommunity/postgres-exporter | 9187 | monitoring | 6x PostgreSQL instances |
| — | monitoring-redis-exporter | oliver006/redis_exporter | 9121 | monitoring | 2x Redis/Valkey instances |
| — | monitoring-tempo | grafana/tempo | 3200, 4318 | monitoring | Distributed tracing |
| — | monitoring-blackbox-exporter | prom/blackbox_exporter | 9115 | monitoring | Synthetic probes |
| — | security-crowdsec | crowdsecurity/crowdsec | 8080 | security | Intrusion detection |
| `forgejo` | operations-forgejo | code.forgejo.org/forgejo/forgejo | 3000 | operations | Git hosting + CI |
| — | operations-postgres-forgejo | postgres | 5432 | operations | Forgejo database |
| — | operations-forgejo-runner | data.forgejo.org/forgejo/runner | — | operations | CI/CD runner |
| `registry-forgejo` | operations-forgejo | (same) | 3000 | operations | Container registry |
| `matrix` | collaboration-synapse | matrixdotorg/synapse | 8008, 8448, 19090 | collaboration | Matrix homeserver |
| `element` | collaboration-element | vectorim/element-web | 80 | collaboration | Matrix web client |
| `hookshot` | collaboration-hookshot | halfshot/matrix-hookshot | 8080 | collaboration | GitHub ↔ Matrix bridge |
| — | collaboration-postgres | postgres | 5432 | collaboration | Synapse database |
| `ocis` | storage-ocis | owncloud/ocis | 9200 | storage | File storage (ownCloud) |
| `collabora` | storage-collabora | collabora/code | 9980 | storage | Online document editing |
| — | storage-collaboration | owncloud/ocis | 9300 | storage | oCIS WOPI collaboration svc |
| `akaunting` | accounting-akaunting | akaunting/akaunting | 80 | accounting | Accounting software |
| — | accounting-mariadb-akaunting | mariadb | 3306 | accounting | Akaunting database |
| — | accounting-mariadb-exporter | prom/mysqld-exporter | 9104 | accounting | MariaDB metrics |
| `homepage` | utility-homepage | ghcr.io/gethomepage/homepage | 3000 | utility | Personal dashboard |
| `vault` | vaultwarden-server | vaultwarden/server | 80 | vaultwarden | Password manager |
| `rss` | rss-freshrss | freshrss/freshrss | 80 | rss | Feed reader |
| — | rss-postgres | postgres | 5432 | rss | FreshRSS database |
| `photos` | photos-server | ghcr.io/immich-app/immich-server | 2283, 8081 | photos | Photo management |
| — | photos-ml | ghcr.io/immich-app/immich-machine-learning | 3003 | photos | ML image tagging |
| — | photos-postgres | ghcr.io/immich-app/postgres | 5432 | photos | Immich database |
| — | photos-valkey | valkey/valkey | 6379 | photos | Immich cache |
| `docs` | documents-webserver | ghcr.io/paperless-ngx/paperless-ngx | 8000 | documents | Document management |
| — | documents-postgres | postgres | 5432 | documents | Paperless database |
| — | documents-redis | redis | 6379 | documents | Paperless cache |
| `vpn` | vpn-wireguard | linuxserver/wireguard | 51820 | vpn | WireGuard VPN |
| — | infra-tunnel | cloudflare/cloudflared | 4788 | tunnel | Cloudflare Tunnel (host net) |
| — | infra-webhook | infra-webhook (build) | 9000 | webhook | Deploy webhook receiver |
| — | backup-restic | restic/restic | — | backup | Backup container |
| — | backup-cron-trigger | (build) | — | backup | Cron scheduler |
| — | updater-watchtower | containrrr/watchtower | — | updater | Update monitor (notify only) |

Plus init containers: `monitoring-prometheus-init`, `monitoring-grafana-init`, `monitoring-postgres-exporter-init`,
`monitoring-textfile-init`, `collaboration-postgres-init`, `collaboration-synapse-init`,
`collaboration-synapse-chown`, `collaboration-element-init`, `documents-postgres-init`, `rss-db-init`,
`storage-ocis-init`.

---

## Network Architecture

### Docker Networks

| Network | Purpose | Attached Containers |
|---|---|---|
| `traefik_net` | Ingress — public-facing containers only | Traefik, OAuth2-Proxy, all services with Traefik labels, well-known-server |
| `backend_net` | Application — internal service communication | Socket-proxy, all apps, all exporters, CrowdSec, OAuth2-Proxy |
| `data_net` | Database — PostgreSQL, MariaDB, Redis, Valkey | All databases, postgres-exporter, redis-exporter, mariadb-exporter |

### Traefik Entrypoints

| Entrypoint | Port | Usage |
|---|---|---|
| `web` | 80 | HTTP → redirects to websecure |
| `websecure` | 443 | HTTPS (Cloudflare DNS challenge TLS) |
| `matrix` | 8448 | Matrix federation (TCP TLS passthrough) |
| `traefik` | 8080 | Prometheus metrics (backend_net only) |

### Traefik Middlewares

| Middleware | Type | Purpose |
|---|---|---|
| `keycloak-auth` | forwardAuth | OAuth2-Proxy → Keycloak SSO |
| `global-rate-limit` | rateLimit | 100 req/s avg, 50 burst |

### Cloudflare Tunnel

SSH and deploy webhook route through `infra-tunnel` (Cloudflare Tunnel, `host` network mode).
CNAME records: `ssh.wyattau.com` → `75ad59d3-...cfargotunnel.com`, `deploy.wyattau.com` → same.

---

## Authentication

**SSO:** Keycloak (auth.wyattau.com, realm: `company-realm`) via OAuth2-Proxy forwardAuth middleware.

Services behind Keycloak auth (middleware `keycloak-auth`):
- Traefik dashboard (`traefik.wyattau.com`)
- Prometheus (`prometheus.wyattau.com`)
- Uptime Kuma (`kuma.wyattau.com`)
- Forgejo (`forgejo.wyattau.com`)
- Akaunting (`akaunting.wyattau.com`)
- Homepage (`homepage.wyattau.com`)

Services with their own auth (no Keycloak middleware):
- Vaultwarden — Bitwarden clients cannot handle OAuth2 redirects
- Immich — Mobile apps/CLI use native auth
- Grafana — Uses Keycloak OIDC directly (not via forwardAuth)

Public-facing (no auth required):
- Element, Collabora, oCIS, FreshRSS, Paperless, Hookshot (rate-limited only)

Keycloak OIDC clients (managed in Terraform):
- `oauth2-proxy` — ForwardAuth for Traefik
- `grafana` — Direct OIDC integration
- `forgejo` — SSO login

---

## Monitoring Stack

### Prometheus (monitoring-prometheus)

**Scrape targets (22 jobs):**
prometheus, node-exporter, cadvisor, traefik, forgejo, keycloak, loki, synapse, alertmanager,
promtail, postgres-exporter (6 PG), vaultwarden, immich, paperless, grafana, redis (2 instances),
mariadb, uptime-kuma, oauth2-proxy, collabora, cloudflared, tempo, crowdsec,
blackbox-http-internal (8 targets), blackbox-http-external (4 targets),
blackbox-tcp (9 targets), blackbox-dns (4 targets).

**Recording rules (4 groups):**
- `slo:availability` — 5m/30m/1h/6h/1d/3d/30d availability ratios
- `slo:http_errors` — 5xx error ratios + request rate per Traefik service
- `slo:container_health` — Container up ratio + down count
- `slo:backup` — Backup age + compliance check

**Alert rules (15 groups, 35+ alerts):**
- `container_health` — ContainerOOMKilled, ContainerHighMemoryUsage, ContainerHighCPUUsage, ContainerRestartLoop, ContainerDown
- `host_health` — HostHighMemoryUsage, HostHighDiskUsage, DataPoolHighDiskUsage, HostDiskInodesExhausted, HostHighCPUUsage, HostClockNotSynchronized, HostDiskIOErrors
- `service_health` — TraefikHighErrorRate, TraefikRateLimitTriggered, PrometheusTSDBCompactionFailure
- `synapse_health` — SynapseHighEventFetchBacklog, SynapseDown
- `loki_health` — LokiTooManyFailedRequests, LokiDown
- `backup_health` — BackupContainerDown, BackupStale, BackupOffsiteSyncStale
- `system_health` — HostDiskFull, HostMemoryExhaustion
- `alertmanager_health` — AlertmanagerDown
- `tls_health` — TLSCertificateExpiringSoon, TLSCertificateCriticalExpiry
- `keycloak_health` — KeycloakDown, KeycloakHighMemoryUsage
- `forgejo_health` — ForgejoDown
- `application_health` — VaultwardenDown, ImmichDown, PaperlessDown, GrafanaDown
- `swap_health` — HighSwapUsage
- `monitoring_pipeline_health` — MonitoringExporterDown
- `server_health` — ServerWidespreadOutage
- `slo_availability_critical` — SLOCriticalAvailabilityBurn, SLOCriticalAvailabilityWarning
- `slo_availability_important` — SLOImportantAvailabilityBurn, SLOImportantAvailabilityWarning
- `slo_http_errors` — SLOHTTPErrorBudgetBurn, SLOHTTPErrorBudgetWarning
- `slo_30d_compliance` — SLOMonthlyCriticalAtRisk, SLOMonthlyImportantAtRisk
- `synthetic_monitoring` — SyntheticHTTPInternalFailure, SyntheticHTTPExternalFailure, SyntheticTCPFailure, SyntheticDNSFailure, SyntheticHTTPLatency

**SLO targets:**
- Critical (99.9%): traefik, keycloak
- Important (99.5%): forgejo, grafana, loki, synapse
- HTTP errors (99.5% success rate): all Traefik services

### Grafana (monitoring-grafana)

**Provisioned dashboards (10):**
- `capacity-planning.json` — Resource capacity planning
- `slo-overview.json` — SLO compliance + burn rates
- `postgresql-overview.json` — PostgreSQL cluster health
- `container-resources.json` — Container CPU/memory/disk
- `forgejo-ci.json` — Forgejo CI pipeline status
- `host-overview.json` — Host CPU/memory/disk/network
- `keycloak-iam.json` — Keycloak auth metrics
- `loki-logs.json` — Log volume and query analytics
- `synapse-matrix.json` — Matrix federation health
- `traefik-traffic.json` — HTTP traffic and error rates

### Other Monitoring Components

| Component | Container | Purpose |
|---|---|---|
| Loki + Promtail | monitoring-loki, monitoring-promtail | Log aggregation from all containers |
| Alertmanager | monitoring-alertmanager | Routes alerts → ntfy.sh |
| Tempo | monitoring-tempo | Distributed tracing (Traefik OTLP export) |
| Blackbox Exporter | monitoring-blackbox-exporter | Synthetic HTTP/TCP/DNS probes |
| CrowdSec | security-crowdsec | Collaborative intrusion detection (detection-only mode) |
| Node Exporter | monitoring-node-exporter | Host CPU/memory/disk/network |
| cAdvisor | monitoring-cadvisor | Container resource metrics |
| PostgreSQL Exporter | monitoring-postgres-exporter | 6 PG instances (Forgejo, Keycloak, Synapse, FreshRSS, Immich, Paperless) |
| Redis Exporter | monitoring-redis-exporter | 2 instances (Immich Valkey, Paperless Redis) |
| MariaDB Exporter | accounting-mariadb-exporter | 1 MariaDB instance (Akaunting) |

---

## Security Measures

### Cloudflare Edge
- **WAF:** Zone-level custom ruleset for geo-blocking
- **Geo-blocking:** CN, RU, KP, IR, SY (exceptions: Matrix federation, OIDC discovery, ACME, Hookshot)
- **TLS:** Cloudflare proxy (proxied=true) with DNS challenge certificate renewal
- **DDoS:** Automatic DDoS protection via Cloudflare

### Application Security
- **OAuth2-Proxy:** Keycloak forwardAuth middleware on protected services
- **Rate limiting:** 100 req/s average, 50 burst (global-rate-limit middleware)
- **CrowdSec:** Collaborative intrusion detection (detection-only, no active bouncer yet)
- **Network segmentation:** data_net isolates databases from application containers

### Container Hardening
- `no-new-privileges: true` on all containers (except Collabora, VPN)
- `cap_drop: ALL` on webhook and tunnel containers
- `read_only: true` on backup-restic and proxy-well-known-server
- Resource memory/CPU limits on all containers
- Docker socket mounted `:ro` everywhere
- Log rotation: `max-size: 10m`, `max-file: 3` on all containers

### Secrets Management
- All secrets encrypted with SOPS + age (single key)
- Decrypted to `.secrets.tmp/` only during deploy, wiped after
- `.forgejo_token` committed to git (non-sensitive admin token)

---

## Backup Strategy

| Parameter | Value |
|---|---|
| Schedule | Daily at 02:00 UTC (cron: `0 2 * * *`) |
| Keycloak export | Daily at 01:30 UTC (cron: `30 1 * * *`) |
| Local storage | Restic at `/mnt/pool_HDD_x2/tank/datasources/sis/backups/restic-repo` |
| Offsite | Backblaze B2 sync after each local backup |
| Retention | hourly:24, daily:7, weekly:4, monthly:6, yearly:3 |
| Restore test | Monthly, 1st at 03:00 UTC |
| Backup scope | `/data` (app data) + `/terraform` (Terraform state) |

### Monitoring
- `restic check` runs after every backup
- Backup freshness exported as Prometheus metric (`sis_backup_last_success`)
- Alert if no successful backup in 26 hours (`BackupStale`)
- Alert if no offsite sync in 48 hours (`BackupOffsiteSyncStale`)

---

## Terraform IaC (68 resources)

### Cloudflare DNS (terraform/cloudflare.tf)
- 20 A records (active services → 62.49.93.199)
- 20 AAAA records (active services → 2a0a:ef40:1175:d801:6e4b:90ff:fe48:c063)
- 2 CNAME records (ssh, deploy → Cloudflare Tunnel)
- 1 TXT record (SPF: `v=spf1 include:_spf.mx.cloudflare.net ~all`)
- 1 TXT record (DMARC: `v=DMARC1; p=none; rua=mailto:...`)
- 1 TXT record (Google site verification)
- 1 WAF ruleset (geo-blocking: CN, RU, KP, IR, SY)
- VPN record is DNS-only (not proxied) for WireGuard

### Keycloak Identity (terraform/keycloak.tf)
- 3 OIDC clients: oauth2-proxy, grafana, forgejo
- 4 users: wyatt, joshkad, ayo, viswa

### Forgejo Organization (terraform/forgejo.tf)
- 6 organizations: QuestHive, BlocMarket, Rankhub, Aether, Deontic, Suture
- 6 teams: Owners (one per org)
- 7 team memberships

---

## CI/CD Pipeline

### GitHub Actions (`.github/workflows/validate.yml`)

Runs on push to `main`/`feature/*` and PRs to `main`:

1. **Compose Validation** — yamllint, docker compose config, OPA policy check (conftest)
2. **Ansible Syntax Check** — ansible-playbook --syntax-check, inventory validation
3. **Trivy Security Scan** — Dockerfile fs scan + compose config scan (HIGH/CRITICAL)

### Deploy Pipeline

```
GitHub push → webhook (POST to deploy.wyattau.com)
  → deploy.sh → ansible-playbook ansible/playbooks/site.yml
    → prepare:       git sync + SOPS decrypt to .secrets.tmp/
    → include_vars:  load 17 dotenv files as Ansible variables
    → terraform:     init + plan + apply (if changes)
    → expand:        Jinja2 template rendering (hookshot config, etc.)
    → detect:        identify bind-mount config changes
    → deploy:        docker compose up -d for each stack (17 stacks)
    → handlers:      restart containers with changed configs
    → configure:     Keycloak SMTP via API, Hookshot bridge setup
    → health:        poll 37 health-check containers until healthy
    → rescue:        git reset --hard to previous commit + redeploy
    → cleanup:       rm -rf .secrets.tmp/*
```

**Stack deployment order:** tunnel → security → proxy → iam → monitoring → operations →
collaboration → storage → accounting → utility → backup → vaultwarden → rss → photos →
documents → vpn → updater

**Rollback:** Automatic. On failure, Ansible resets git to the pre-deploy SHA and redeploys.

---

## Key Paths (TrueNAS Server)

| Path | Purpose |
|---|---|
| `/mnt/pool_HDD_x2/infra/stacks` | Git repo clone (compose files, Ansible, Terraform) |
| `/mnt/pool_HDD_x2/tank/datasources/sis/appdata` | Application data volumes |
| `/mnt/pool_HDD_x2/tank/datasources/sis/backups` | Local Restic backup repository |
| `/mnt/pool_HDD_x2/infra/bin/terraform` | Terraform binary |
| `/mnt/pool_HDD_x2/infra/bin/docker-compose` | Docker Compose binary |
| `/root/.config/sops/age/keys.txt` | Age encryption private key |
| `/var/log/infra-deploy.log` | Deploy log output |

---

## Secrets Management

- **17 SOPS-encrypted files** in `secrets/` (one per stack + backup):
  security, iam, accounting, collaboration, backup, monitoring, proxy, storage, utility,
  operations, documents, photos, rss, updater, vpn, vaultwarden, tunnel
- **Encryption:** age (single key)
- **Public key:** `age13kqew6kglat9hlswcstcxpdtvfh8v7pckr0wt3qvqkn7u2cj3e6qnm03uc`
- **Config:** `.sops.yaml` — matches `^secrets/.*\.env\.encrypted$`
- **Decryption:** During deploy, decrypted to `.secrets.tmp/*.env`, converted to YAML,
  loaded as Ansible variables, then wiped in `post_tasks`
- **`.forgejo_token`:** Committed to git (non-sensitive admin API token for Terraform)

---

## Operational Procedures

### Trigger a Deploy

```bash
curl -X POST https://deploy.wyattau.com/hooks/deploy \
  -H "X-Hub-Signature-256: sha256=<hmac>" \
  -H "Content-Type: application/json" \
  -d '{}'
```

HMAC uses the shared secret configured in the webhook container.

### Add a New Stack

1. Create `stacks/<name>/docker-compose.yml` with `${VAR}` references
2. Create `secrets/<name>.env.encrypted` with `sops -e`
3. Add stack name to `stacks:` list in `ansible/inventory/group_vars/all.yml`
4. Add DNS record to `terraform/cloudflare.tf` `active_services` map
5. Add containers to `health_check_containers` if they have healthchecks
6. Commit and push — webhook triggers deploy

### Update a Secret

```bash
sops secrets/<stack>.env.encrypted
# Edit value, save (SOPS re-encrypts automatically)
git add secrets/<stack>.env.encrypted
git commit -m "update <stack> secret"
git push
```

### Add a New Grafana Dashboard

1. Create/update JSON in `stacks/monitoring/grafana/provisioning/dashboards/<name>.json`
2. Grafana auto-loads from the provisioning directory
3. Commit and push

### Add a New Prometheus Alert

1. Add rule to `stacks/monitoring/prometheus/alert_rules.yml` under appropriate group
2. Optionally add recording rule to `stacks/monitoring/prometheus/recording_rules.yml`
3. Test locally: `docker exec monitoring-prometheus promtool check rules /etc/prometheus/alert_rules.yml`
4. Commit and push

### Restore from Backup

```bash
# Enter backup container
sudo docker exec -it backup-restic sh

# List snapshots
restic -r /restic-repo snapshots

# Restore specific data
restic -r /restic-repo restore latest --target /tmp/restore --include "/data/<stack>/*"
sudo cp -a /tmp/restore/data/<stack>/* /mnt/pool_HDD_x2/tank/datasources/sis/appdata/<stack>/

# Restore from B2 offsite
export AWS_ACCESS_KEY_ID="<key>" AWS_SECRET_ACCESS_KEY="<secret>"
restic -r b2:<bucket>:repo restore latest --target /tmp/restore
```

### Rolling Update an Image

Images are version-pinned via `versions.env` files per stack. Renovate auto-opens PRs.
To update manually: change the version in `versions.env`, commit, push.

---

## Related Documentation

- [docs/disaster-recovery-runbook.md](disaster-recovery-runbook.md) — Full DR procedures (container crash, pool corruption, full server recovery, compromised secrets)
- [.sops.yaml](../.sops.yaml) — SOPS encryption configuration
- [terraform/variables.tf](../terraform/variables.tf) — Terraform variable definitions

---

## Appendix A: Secrets Rotation Guide

### Rotation Schedule (Recommended)

| Secret | Location | Frequency | Complexity |
|--------|----------|-----------|------------|
| Cloudflare API token | `secrets/proxy.env.encrypted` | Annually | Low — Cloudflare dashboard + update SOPS |
| Keycloak client secrets | `secrets/proxy.env.encrypted`, `secrets/iam.env.encrypted`, `secrets/monitoring.env.encrypted` | Annually | Low — Keycloak Admin Console + update SOPS |
| Keycloak admin password | `secrets/iam.env.encrypted` | Annually | Low — Keycloak Admin Console + update SOPS |
| Database passwords | Per-stack `.env.encrypted` | Annually | Medium — ALTER USER + update SOPS + update postgres-exporter .pgpass |
| Forgejo admin token | `.forgejo_token` | On compromise | Low — `gitea admin user generate-access-token` |
| Webhook shared secret | `secrets/tunnel.env.encrypted` + GitHub Actions secret | On compromise | Medium — generate new + update both locations |
| Age encryption key | `~/.config/sops/age/keys.txt` | Emergency only | High — re-encrypt ALL 17 secret files |
| SMTP password | `secrets/iam.env.encrypted` | If leaked | Low — update ProtonMail + update SOPS |

### Rotation Procedure

For any secret rotation:

1. **Generate new value** (via admin UI, CLI command, or `openssl rand -hex 32`)
2. **Update the SOPS-encrypted file:**
   ```bash
   sops -d --input-type dotenv --output-type dotenv secrets/<stack>.env.encrypted > /tmp/<stack>.env
   # Edit the value
   nano /tmp/<stack>.env
   sops -e --input-type dotenv --output-type dotenv /tmp/<stack>.env > secrets/<stack>.env.encrypted
   rm /tmp/<stack>.env
   ```
3. **Commit and push** — deploy pipeline will use the new value on next deploy
4. **Verify** — check the service still works after deploy

### Age Key Rotation (Emergency Only)

If the age key is compromised, ALL secrets must be re-encrypted:

1. Generate new key: `age-keygen -o ~/.config/sops/age/keys.txt`
2. Copy new public key to `.sops.yaml`
3. Re-encrypt all secret files:
   ```bash
   for f in secrets/*.env.encrypted; do
     sops updatekeys -y "$f"
   done
   ```
4. Copy new key to server: `sudo cp ~/.config/sops/age/keys.txt /root/.config/sops/age/keys.txt`
5. Test decryption: `sops -d secrets/proxy.env.encrypted`

---

## Appendix B: Container Image Signing Assessment

Container image signing (Cosign/Notation) adds supply chain verification by cryptographically
signing container images to prove they haven't been tampered with.

### Current Status: Not Implemented

### Assessment

| Factor | Evaluation |
|--------|------------|
| Attack surface | Low — images pulled from trusted registries (GHCR, Docker Hub, Quay) |
| Benefit | Medium — detect compromised upstream images |
| Cost | High — requires Cosign + key management + signing pipeline |
| Complexity | High — every image needs signing, rotation, verification |
| Applicability | Low — personal homelab, not a production environment |

### Future Implementation (If Needed)

If image signing becomes necessary:

1. **Generate Cosign key pair:** `cosign generate-key-pair`
2. **Sign images in CI:** Add Cosign step to GitHub Actions validate.yml
3. **Verify on deploy:** Add Cosign verification to Ansible prepare role
4. **Key rotation:** Annual key rotation, store private key securely

### Current Mitigations (Without Signing)

- Images are version-pinned via `versions.env` (no `latest` tags)
- Renovate tracks upstream vulnerabilities (daily Trivy scan)
- `v2.32.3` Docker Compose doesn't support `--ansi` flag (version pinned)
- Trusted registries only: ghcr.io, docker.io, quay.io
- Daily vulnerability scanning via GitHub Actions (`vulnerability-scan.yml`)
