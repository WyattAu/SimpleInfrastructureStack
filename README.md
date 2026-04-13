# SimpleInfrastructureStack

Self-hosted infrastructure stack running on TrueNAS SCALE with defense-in-depth security, automated CI/CD, and full observability.

## Architecture

```
GitHub (push to main)
  │
  ▼
GitHub Actions (validate: lint + compose + conftest + ansible)
  │
  ▼
Webhook (Cloudflare Tunnel) ──▶ TrueNAS SCALE
                                  │
                                  ▼
                              Ansible (site.yml)
                                  │
                                  ├── SOPS decrypt → template expansion
                                  ├── docker compose up (9 stacks)
                                  ├── health check (22 containers)
                                  └── SOPS cleanup
```

### Runtime Architecture

```
Internet
  │
  ▼
Cloudflare DNS (DDNS + Proxy)
  │
  ▼
TrueNAS SCALE Host
  ├── Port 80/443 ──▶ Traefik ──▶ OAuth2-Proxy ──▶ Keycloak (OIDC)
  │                    │
  │                    └── Socket-Proxy ──▶ Docker API (restricted read-only)
  │
  ├── [traefik_net]   Public-facing services (Traefik labels)
  └── [backend_net]   Internal service communication (databases, monitoring)
```

### Security

| Layer | Implementation |
|-------|---------------|
| TLS | Automatic Let's Encrypt via Cloudflare DNS-01 challenge |
| Authentication | Centralized Keycloak SSO via OAuth2-Proxy forward auth |
| Container Isolation | `no-new-privileges:true` on all services (except Collabora) |
| Network Segmentation | 2 isolated networks: public (`traefik_net`), internal (`backend_net`) |
| CI/CD Security | Pull-based webhook via Cloudflare Tunnel, no SSH keys exposed |
| Secrets | SOPS age-encrypted `.env.encrypted` files, decrypted only at deploy time |
| Image Integrity | All images pinned to specific versions, enforced by OPA policy |
| Policy Enforcement | Conftest/OPA policies run in CI against every compose file |

### Stacks

| Stack | Services | Purpose |
|-------|----------|---------|
| `proxy` | Traefik, OAuth2-Proxy, Cloudflare DDNS, Socket-Proxy | Gateway, TLS, SSO |
| `iam` | Keycloak, PostgreSQL | Identity management |
| `operations` | Forgejo, Forgejo Runner, Woodpecker CI/CD, PostgreSQL | Git hosting, CI/CD |
| `collaboration` | Synapse, Element Web, PostgreSQL | Matrix chat |
| `storage` | oCIS, Collabora Online | File storage, document editing |
| `monitoring` | Prometheus, Grafana, Loki, Promtail, Uptime Kuma, cAdvisor, Node Exporter | Metrics, logs, uptime |
| `utility` | Homepage | Personal dashboard |
| `accounting` | Akaunting, PostgreSQL | Self-hosted accounting |
| `backup` | Restic, Cron Trigger (local + Backblaze B2 offsite) | Automated backups |

## Deployment

### Prerequisites

- Shell (SSH) access to the TrueNAS SCALE host
- SOPS age key on both local machine and server
- GitHub Actions secrets configured: `WEBHOOK_URL`, `WEBHOOK_SECRET`, `SOPS_AGE_PUBLIC_KEY`, `RENOVATE_TOKEN`

### How Deployment Works

1. **Push to `main`** triggers GitHub Actions
2. **CI validates**: yamllint, docker compose config, conftest OPA policies, ansible syntax
3. **On success**: GitHub Actions POSTs to the webhook URL
4. **Webhook container** on TrueNAS receives the payload, verifies HMAC
5. **Ansible pipeline** runs: git pull → SOPS decrypt → template expansion → `docker compose up` → health checks → SOPS cleanup
6. **Health check** verifies all 22 containers are healthy; deploy fails if any are unhealthy

### Manual Deploy

```bash
ssh -i ~/.ssh/id_ed25519 truenas_admin@192.168.1.3
sudo docker exec infra-webhook bash /opt/webhook/deploy.sh
```

### CI Pipeline

GitHub Actions runs on every push to `main` and on PRs:

| Job | Checks |
|-----|--------|
| Compose Validation | yamllint, docker compose config, conftest OPA policies |
| Ansible Syntax | Playbook syntax check, inventory validation |

## Secrets Management

Secrets are stored as SOPS age-encrypted files in `secrets/*.env.encrypted`. They are:

- **Never committed in plaintext** (`.gitignore` excludes `*.env`)
- **Decrypted only at deploy time** inside the Ansible pipeline
- **Cleaned up immediately** after deploy completes
- **Encrypted with age** — key at `~/.config/sops/age/keys.txt`

### Editing secrets on the server

```bash
sudo docker exec infra-webhook sops -d --input-type dotenv --output-type dotenv \
  --config /mnt/pool_HDD_x2/infra/stacks/.sops.yaml \
  /mnt/pool_HDD_x2/infra/stacks/secrets/<stack>.env.encrypted
```

## OPA/Conftest Policies

Security policies in `policies/docker-compose/security.rego` enforce:

- No `privileged: true`
- `no-new-privileges:true` on all long-running services (except Collabora)
- No `:latest` image tags on long-running services
- Resource limits on all long-running services
- Logging configured on all long-running services
- No unauthorized Docker socket RW mounts
- No RW mounts to sensitive host paths

### Exception Registry

| Exception | Service | Reason |
|-----------|---------|--------|
| No `no-new-privileges` | `collabora` | Requires `CLONE_NEWUSER` for document sandboxing |
| Docker socket RW | `forgejo-runner` | Executes Docker builds and job containers |
| `:latest` tag | `infra-webhook` | Locally-built image, not pulled from registry |
| Init containers | `*-init`, `*-chown` | Ephemeral one-shot containers |

## Monitoring & Alerting

### Prometheus Alert Rules (`alert_rules.yml`)

- Container OOM kills, high memory/CPU, restart loops, downed containers
- Host memory, disk, inode exhaustion
- Service health: Traefik 5xx rate, Prometheus TSDB, Synapse, Loki
- Backup container down detection

### Grafana Log Alerts (`rules.yml`)

- Keycloak error rate (Loki)
- Synapse error rate (Loki)
- Traefik error rate (Loki)
- OOM kill events (Loki)

Alerts route to ntfy.sh topics:
- **Warning**: `https://ntfy.sh/wyattau-infra-0e92568ce5d04343c3b796ed558a04b9`
- **Critical**: `https://ntfy.sh/wyattau-infra-0e92568ce5d04343c3b796ed558a04b9-critical`

## Backups

- **Local**: Restic to ZFS dataset, daily at 02:00 UTC
- **Offsite**: Restic copy to Backblaze B2 (eu-central-003)
- **Retention**: 24 hourly, 7 daily, 4 weekly, 6 monthly, 3 yearly
- **Verification**: Automatic restore test after each backup run

## Local Development

```bash
make install-hooks    # Install pre-commit hooks
make lint             # Run all checks (yamllint, prettier)
make format           # Format YAML and Markdown files
```

## Keycloak SSO Configuration

Services protected by Keycloak authentication (via `keycloak-auth` Traefik middleware):

- Traefik Dashboard (`traefik.wyattau.com`)
- Homepage (`homepage.wyattau.com`)
- Uptime Kuma (`kuma.wyattau.com`)
- Prometheus (`prometheus.wyattau.com`)
- Forgejo Web UI (`forgejo.wyattau.com`)

Services with built-in auth (not behind Keycloak):

- Forgejo Container Registry (uses Forgejo token auth for `docker login`)
- Keycloak Admin Console (self-managed)
- Grafana (uses Keycloak OIDC directly, not via Traefik middleware)

Services publicly accessible:

- Matrix federation endpoint (`matrix.wyattau.com:8448`)
- Element Web (`element.wyattau.com` — SSO via Synapse, not Keycloak)
