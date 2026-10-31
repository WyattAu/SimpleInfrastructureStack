# SimpleInfrastructureStack: Infrastructure Documentation
- `traefik_net`; ingress network. Only containers that serve HTTP/Traefik attach here.
- `backend_net`; application network. Inter-service communication (exporters, metrics, internal APIs).
- `data_net`; database network. PostgreSQL, MariaDB, Redis, Valkey instances only.
| - | proxy-socket-proxy | tecnativa/docker-socket-proxy | - | proxy | Docker socket proxy for Traefik |
| - | proxy-oauth2-proxy | quay.io/oauth2-proxy/oauth2-proxy | 4180 | proxy | Keycloak forwardAuth middleware |
| - | proxy-cloudflare-ddns | favonia/cloudflare-ddns | - | proxy | Dynamic DNS updates (*/5 min) |
| - | iam-postgres | postgres | 5432 | iam | Keycloak database |
| - | monitoring-victorialogs | victoriametrics/victoria-logs | 9428 | monitoring | Log aggregation (Loki-compatible) |
| - | monitoring-promtail | grafana/promtail | - | monitoring | Log shipper → VictoriaLogs |
| - | monitoring-vmalert | victoriametrics/vmalert | 8880 | monitoring | Alerting engine (Prometheus-compatible) |
| - | monitoring-alertmanager | prom/alertmanager | 9093 | monitoring | Alert routing → ntfy |
| - | monitoring-node-exporter | prom/node-exporter | 9100 | monitoring | Host metrics |
| - | monitoring-cadvisor | ghcr.io/google/cadvisor | 8080 | monitoring | Container metrics |
| - | monitoring-postgres-exporter | quay.io/prometheuscommunity/postgres-exporter | 9187 | monitoring | 6x PostgreSQL instances |
| - | monitoring-redis-exporter | oliver006/redis_exporter | 9121 | monitoring | 2 Redis/Valkey instances (Paperless Redis, Immich Valkey) |
| - | monitoring-tempo | grafana/tempo | 3200, 4318 | monitoring | Distributed tracing |
| - | monitoring-blackbox-exporter | prom/blackbox_exporter | 9115 | monitoring | Synthetic probes |
| - | security-crowdsec | crowdsecurity/crowdsec | 8080 | security | Intrusion detection |
| - | security-cf-workers-bouncer | crowdsecurity/cf-workers-bouncer | - | security | Cloudflare WAF bouncer |
| - | operations-postgres-forgejo | postgres | 5432 | operations | Forgejo database |
| - | operations-forgejo-runner | data.forgejo.org/forgejo/runner | - | operations | CI/CD runner |
| - | collaboration-postgres | postgres | 5432 | collaboration | Synapse database |
| - | storage-collaboration | owncloud/ocis | 9300 | storage | oCIS WOPI collaboration svc |
| - | accounting-mariadb-akaunting | mariadb | 3306 | accounting | Akaunting database |
| - | accounting-mariadb-exporter | prom/mysqld-exporter | 9104 | accounting | MariaDB metrics |
| - | rss-postgres | postgres | 5432 | rss | FreshRSS database |
| - | photos-ml | ghcr.io/immich-app/immich-machine-learning | 3003 | photos | ML image tagging |
| - | photos-postgres | ghcr.io/immich-app/postgres | 5432 | photos | Immich database |
| - | photos-valkey | valkey/valkey | 6379 | photos | Immich cache |
| - | documents-postgres | postgres | 5432 | documents | Paperless database |
| - | documents-redis | redis | 6379 | documents | Paperless cache |
| - | infra-tunnel | cloudflare/cloudflared | 4788 | tunnel | Cloudflare Tunnel (host net) |
| - | infra-webhook | infra-webhook (build) | 9000 | webhook | Deploy webhook receiver |
| - | backup-restic | restic/restic | - | backup | Backup container |
| - | backup-cron-trigger | (build) | - | backup | Cron scheduler |
| - | updater-watchtower | containrrr/watchtower | - | updater | Update monitor (notify only) |
| - | project-management-* | (multiple taiga images) | - | project-management | Project management |
| `traefik_net` | Ingress; public-facing containers only | Traefik, OAuth2-Proxy, all services with Traefik labels, well-known-server |
| `backend_net` | Application; internal service communication | Socket-proxy, all apps, all exporters, CrowdSec, OAuth2-Proxy |
| `data_net` | Database; PostgreSQL, MariaDB, Redis, Valkey | All databases, postgres-exporter, redis-exporter, mariadb-exporter |
- Vaultwarden; Bitwarden clients cannot handle OAuth2 redirects
- Immich; Mobile apps/CLI use native auth
- Grafana; Uses Keycloak OIDC directly (not via forwardAuth)
- `oauth2-proxy`; ForwardAuth for Traefik
- `grafana`; Direct OIDC integration
- `forgejo`; SSO login
- `slo:availability`; 5m/30m/1h/6h/1d/3d/30d availability ratios
- `slo:http_errors`; 5xx error ratios + request rate per Traefik service
- `slo:container_health`; Container up ratio + down count
- `slo:backup`; Backup age + compliance check
- `container_health`; ContainerOOMKilled, ContainerHighMemoryUsage, ContainerHighCPUUsage, ContainerRestartLoop, ContainerDown
- `host_health`; HostHighMemoryUsage, HostHighDiskUsage, DataPoolHighDiskUsage, HostDiskInodesExhausted, HostHighCPUUsage, HostClockNotSynchronized, HostDiskIOErrors
- `service_health`; TraefikHighErrorRate, TraefikRateLimitTriggered
- `synapse_health`; SynapseHighEventFetchBacklog, SynapseDown
- `logs_health`; LogsTooManyFailedRequests, LogsDown
- `backup_health`; BackupContainerDown, BackupStale, BackupOffsiteSyncStale
- `system_health`; HostDiskFull, HostMemoryExhaustion
- `alertmanager_health`; AlertmanagerDown
- `tls_health`; TLSCertificateExpiringSoon, TLSCertificateCriticalExpiry
- `keycloak_health`; KeycloakDown, KeycloakHighMemoryUsage
- `forgejo_health`; ForgejoDown
- `application_health`; VaultwardenDown, ImmichDown, PaperlessDown, GrafanaDown
- `swap_health`; HighSwapUsage
- `monitoring_pipeline_health`; MonitoringExporterDown
- `server_health`; ServerWidespreadOutage
- `slo_availability_critical`; SLOCriticalAvailabilityBurn, SLOCriticalAvailabilityWarning
- `slo_availability_important`; SLOImportantAvailabilityBurn, SLOImportantAvailabilityWarning
- `slo_http_errors`; SLOHTTPErrorBudgetBurn, SLOHTTPErrorBudgetWarning
- `slo_30d_compliance`; SLOMonthlyCriticalAtRisk, SLOMonthlyImportantAtRisk
- `synthetic_monitoring`; SyntheticHTTPInternalFailure, SyntheticHTTPExternalFailure, SyntheticTCPFailure, SyntheticDNSFailure, SyntheticHTTPLatency
- `capacity-planning.json`; Resource capacity planning
- `slo-overview.json`; SLO compliance + burn rates
- `postgresql-overview.json`; PostgreSQL cluster health
- `container-resources.json`; Container CPU/memory/disk
- `forgejo-ci.json`; Forgejo CI pipeline status
- `host-overview.json`; Host CPU/memory/disk/network
- `keycloak-iam.json`; Keycloak auth metrics
- `victorialogs-logs.json`; Log volume and query analytics
- `synapse-matrix.json`; Matrix federation health
- `traefik-traffic.json`; HTTP traffic and error rates
1. **Compose Validation**; yamllint, docker compose config, OPA policy check (conftest)
2. **Ansible Syntax Check**; ansible-playbook --syntax-check, inventory validation
3. **Trivy Security Scan**; Dockerfile fs scan + compose config scan (HIGH/CRITICAL)
- **Config:** `.sops.yaml`; matches `^secrets/.*\.env\.encrypted$`
6. Commit and push; webhook triggers deploy
- [docs/disaster-recovery-runbook.md](disaster-recovery-runbook.md); Full DR procedures (container crash, pool corruption, full server recovery, compromised secrets)
- [.sops.yaml](../.sops.yaml); SOPS encryption configuration
- [terraform/variables.tf](../terraform/variables.tf); Terraform variable definitions
| Cloudflare API token | `secrets/proxy.env.encrypted` | Annually | Low; Cloudflare dashboard + update SOPS |
| Keycloak client secrets | `secrets/proxy.env.encrypted`, `secrets/iam.env.encrypted`, `secrets/monitoring.env.encrypted` | Annually | Low; Keycloak Admin Console + update SOPS |
| Keycloak admin password | `secrets/iam.env.encrypted` | Annually | Low; Keycloak Admin Console + update SOPS |
| Database passwords | Per-stack `.env.encrypted` | Annually | Medium; ALTER USER + update SOPS + update postgres-exporter .pgpass |
| Forgejo admin token | `.forgejo_token` | On compromise | Low; `gitea admin user generate-access-token` |
| Webhook shared secret | `secrets/tunnel.env.encrypted` + GitHub Actions secret | On compromise | Medium; generate new + update both locations |
| Age encryption key | `~/.config/sops/age/keys.txt` | Emergency only | High; re-encrypt ALL 17 secret files |
| SMTP password | `secrets/iam.env.encrypted` | If leaked | Low; update ProtonMail + update SOPS |