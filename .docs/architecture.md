# SIS Infrastructure Architecture

## Network Topology

```
Internet
  │
  ├── Cloudflare (DNS + Tunnel + Access)
  │     ├── *.wyattau.com → CF Tunnel → TrueNAS:443 (Traefik)
  │     ├── ssh.wyattau.com → CF Tunnel → TrueNAS:2222 (Forgejo SSH)
  │     └── CF Access: OTP auth for SSH
  │
  ├── Vodafone ISP (62.49.88.159)
  │     ├── TrueNAS (192.168.1.3) — 96TB ZFS pool
  │     ├── CachyOS (192.168.1.191) — CI runner server
  │     └── LAN (192.168.1.0/24)
  │
  └── Headscale VPN (headscale.wyattau.com)
        ├── truenas-1 (100.64.0.2) — exit node
        └── cachyos-runner (100.64.0.3)
```

## TrueNAS (192.168.1.3) — 66 Containers

### Proxy Layer
| Container | Image | Function |
|-----------|-------|----------|
| proxy-traefik | EIR traefik:v3.7.3 | Reverse proxy, TLS, routing |
| proxy-oauth2-proxy | EIR oauth2-proxy:v7.15.2 | Keycloak OIDC integration |
| proxy-socket-proxy | EIR docker-socket-proxy:v0.4.2 | Restricted Docker API access |
| infra-tunnel | EIR cloudflared:2026.5.0 | Cloudflare tunnel (host network) |

### Identity Layer
| Container | Image | Function |
|-----------|-------|----------|
| iam-keycloak | EIR keycloak:26.6.2 | OIDC provider (static IP .202) |
| iam-postgres | EIR postgres:17-alpine | Keycloak database |

### CI/CD Layer
| Container | Image | Function |
|-----------|-------|----------|
| operations-forgejo | EIR forgejo:15.0.2 | Git hosting + CI |
| operations-postgres-forgejo | EIR postgres:17-alpine | Forgejo database |

### Monitoring Layer
| Container | Image | Function |
|-----------|-------|----------|
| monitoring-victoriametrics | EIR victoriametrics:v1.143.0 | TSDB (static IP .200) |
| monitoring-vmalert | EIR vmalert:v1.143.0 | Alert rule evaluation (static IP .201) |
| monitoring-alertmanager | EIR alertmanager:v0.32.1 | Alert routing → ntfy.sh |
| monitoring-grafana | EIR grafana:12.2.9 | 19 dashboards |
| monitoring-tempo | EIR tempo:2.10.5 | Distributed tracing |
| monitoring-promtail | EIR promtail:3.6.11 | Log collection |
| + 7 more exporters | EIR | node, blackbox, cadvisor, etc. |

### Application Layer
| Container | Image | Function |
|-----------|-------|----------|
| vaultwarden-server | EIR vaultwarden:1.36.0 | Password manager |
| photos-server/ML | Immich v2.7.5 | Photo management |
| documents-webserver | Paperless 2.20.15 | Document management |
| erpnext-* (6) | Frappe v16.0.0 | ERP |
| collaboration-* (4) | Synapse + Element | Matrix chat |
| storage-ocis | EIR ocis:8.0.4 | File storage |
| + 15 more | Various | Accounting, RSS, books, etc. |

## CachyOS (192.168.1.191) — CI Runners

| Container | Function |
|-----------|----------|
| 4× Forgejo runners | CI job execution (rust-node:2.0.0 image) |
| node-exporter:9100 | Host metrics |
| cadvisor:9090 | Container metrics |
| Tailscale | VPN node (100.64.0.3) |

## EIR Shim Architecture (v2.0.0)

```
┌─────────────────────────────────────────────┐
│ Docker Container                            │
│  ┌───────────────────────────────────────┐  │
│  │ docker-init (tini) — PID 0           │  │
│  │  ┌─────────────────────────────────┐ │  │
│  │  │ shim (PID 1)                    │ │  │
│  │  │  ├── Health server :9101       │ │  │
│  │  │  ├── Background zombie reaper  │ │  │
│  │  │  ├── pidfd monitor (Linux 5.3+)│ │  │
│  │  │  ├── Startup grace (5s)        │ │  │
│  │  │  └── Child process (app)       │ │  │
│  │  │      └── grandchildren...      │ │  │
│  │  └─────────────────────────────────┘ │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

**Key mechanisms:**
- **pidfd_open()**: Kernel notifies instantly when child exits (zero-polling)
- **PR_SET_CHILD_SUBREAPER**: Shim becomes reaper for all descendants
- **waitpid(-1, WNOHANG)**: Background task reaps zombie grandchildren every 100ms
- **/proc/<pid>/status**: Fallback for kernels <5.3
- **Startup grace**: If child exits within 5s, restart once before giving up

## Monitoring Pipeline

```
Containers → exporters → VictoriaMetrics → vmalert (820 rules) → Alertmanager → ntfy.sh → Phone
                 ↓                                                          ↑
            Grafana (19 dashboards)                            Vuln scan (weekly cron)
```

**Alert delivery:** ntfy.sh topic `wyattau-infra-0e92568ce5d04343c3b796ed558a04b9`

## Backup Strategy

| Type | Schedule | Location | Retention |
|------|----------|----------|-----------|
| App data (per stack) | Daily 3AM | Local ZFS | 30 snapshots |
| DB dumps | Daily 3AM | Local ZFS | 30 snapshots |
| Configs (git repo) | Daily 3AM | Local ZFS | 30 snapshots |
| Offsite sync | Daily after local | B2 (eu-central-003) | 30 snapshots |
| Vuln scan | Weekly Sun 4AM | Metrics (.prom) | Latest |

**DR drill:** Vaultwarden restore verified from both local and B2. SQLite integrity OK.

## Security

| Layer | Mechanism |
|-------|-----------|
| Network | Cloudflare proxy + tunnel (no exposed ports) |
| DDoS | Cloudflare edge + rate limiting |
| Auth | Keycloak OIDC via oauth2-proxy |
| Container | cap_drop ALL, no-new-privileges, pids limits |
| Detection | CrowdSec (intrusion detection + CF Workers bouncer) |
| Vuln scanning | Weekly Trivy → vmalert → ntfy |
| Backups | Encrypted restic (local + B2 offsite) |

## IaC

| Tool | Scope |
|------|-------|
| Terraform | 38 resources (CF DNS, Forgejo orgs, Keycloak clients) |
| Ansible | Deploy pipeline (canary checks, smoke tests, chown) |
| GitHub Actions | Auto-deploy on push to main |
| SOPS + age | Secret encryption |

## Manual Action Items

| Task | Location | Time |
|------|----------|------|
| Add DEPLOY_SSH_KEY + TRUENAS_HOST | GitHub repo Settings → Secrets | 5 min |
| Update CF API token (WAF Edit) | Cloudflare Dashboard → Profile → API Tokens | 5 min |
| Install Tailscale on phone | App store → custom server → pre-auth key | 5 min |
| Fix cloudflared SSH cert | Desktop browser → access login | 15 min |
