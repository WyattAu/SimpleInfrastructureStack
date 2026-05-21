# SimpleInfrastructureStack -- Roadmap

Comprehensive improvement plan derived from two full monorepo audits (2026-05-11
initial, 2026-05-14 follow-up). The audits covered: 20 Docker Compose stacks,
7 Ansible playbooks, 4 CI/CD workflows, 68 Terraform resources, 1 OPA policy,
5 documentation files, and all shell scripts.

---

## Current State

### Test Results (2026-05-15)

| Check | Tool | Result |
|-------|------|--------|
| Trailing whitespace | pre-commit-hooks v4.6.0 | PASS |
| End-of-file fixer | pre-commit-hooks v4.6.0 | PASS |
| YAML syntax | check-yaml | PASS |
| JSON syntax | check-json | PASS |
| Merge conflicts | check-merge-conflict | PASS |
| Large files | check-added-large-files | PASS |
| Markdown lint | markdownlint-cli2 v0.18.1 | PASS |
| YAML lint | yamllint v1.37.1 | PASS |
| Docker Compose config | docker compose v5.1.3 | PASS (20/20 stacks) |
| Ansible syntax | ansible-playbook --syntax-check | PASS (6/6 playbooks) |
| Terraform fmt | terraform fmt -check | PASS |
| Shellcheck | shellcheck (severity=warning) | PASS (0 warnings) |
| OPA policy | conftest v0.57.0 | PASS (20/20 stacks) |

### Infrastructure Summary

| Metric | Value |
|--------|-------|
| Stacks | 20 |
| Containers | 65 (running, compose-managed) |
| Networks | 3 (traefik_net, backend_net, data_net) |
| PostgreSQL instances | 6 |
| Terraform resources | 68 |
| OPA DENY rules | 9 |
| OPA WARN rules | 6 |
| Grafana dashboards | 10 |
| Alert rule groups | 20+ |
| SOPS-encrypted files | 19 |
| Memory available | ~3 GiB (16 GiB total) |
| Container deployment drift | 0 (all compose-managed) |

### Server Health (2026-05-15)

| Component | Status |
|-----------|--------|
| proxy-traefik | healthy |
| iam-keycloak | running (healthcheck: slow Java compile, functional) |
| monitoring-victoriametrics | healthy |
| monitoring-alertmanager | healthy |
| monitoring-vmalert | healthy |
| monitoring-grafana | healthy |
| monitoring-cadvisor | healthy |
| monitoring-zfs-exporter | healthy |
| monitoring-node-exporter | healthy |
| collaboration-postgres | healthy (pg_stat_statements v1.12) |
| collaboration-synapse | healthy |
| operations-forgejo | healthy |
| Netdata | disabled (freed ~770 MiB) |

---

## Completed (Audits 1 and 2)

### Initial Audit (2026-05-11)

- [x] All pre-commit hooks pass
- [x] All 20 Docker Compose stacks validate with `docker compose config`
- [x] All 6 Ansible playbooks pass syntax check
- [x] 91 markdownlint errors fixed across 6 documentation files
- [x] 30 YAML files updated with document-start markers
- [x] yamllint errors and warnings resolved
- [x] Webhook compose volume spec fixed
- [x] CI workflow emojis replaced with text labels
- [x] Dead prettier hook reference removed
- [x] Makefile format target fixed

### Roadmap Implementation (2026-05-11)

- [x] P0-1: Fix compose validation exit code bug in validate.yml
- [x] P0-2: Document Cloudflare WAF geo-blocking as disabled
- [x] P0-3: Add recovery key placeholder to .sops.yaml
- [x] P0-4: Fix DR runbook Restic path
- [x] P0-5: Add conftest OPA policy check step to CI
- [x] P1-6: Add cap_drop: ALL to socket-proxy and forgejo-runner
- [x] P1-7: Add pre-backup pg_dump for all 6 PostgreSQL instances
- [x] P1-8: Add Terraform fmt/init/validate job to CI
- [x] P1-9: Add gitleaks secret scanning job to CI
- [x] P1-10: Add ansible-lint job to CI
- [x] P1-11: Add shellcheck job to CI
- [x] P1-12: Add SARIF upload for Trivy vulnerability scans
- [x] P1-13: Fix SMTP provider discrepancy
- [x] P2-14: Add ZFS pool metrics (textfile collector + alert rules)
- [x] P2-15: Log-based alerting (Keycloak, Synapse, Traefik, OOM)
- [x] P2-16: Add backup size metric and alert
- [x] P2-17: Add dump file verification to restore test
- [x] P2-18: Template Alertmanager ntfy URLs
- [x] P2-19: Add pids_limit to all long-running containers
- [x] P2-20: Add no-new-privileges:true to WireGuard VPN
- [x] P2-21: Add CPU limits to memory-heavy containers
- [x] P3-22: Add read_only:true WARN rule to security.rego
- [x] P3-23: Add user directive and cap_drop WARN rules
- [x] P3-24: Add Terraform remote state backend config
- [x] P3-25: Configure Keycloak dedicated service account
- [x] P3-26: Add ignore_changes=[credentials] to Keycloak users
- [x] P3-27: Remove hardcoded defaults from cf_zone_id/cf_account_id
- [x] P3-28: Add GitHub Actions tool caching
- [x] P3-29: Restrict Renovate auto-merge to vetted allowlist
- [x] P3-30: Add CODEOWNERS file
- [x] P3-31: Add markdown-link-check job to CI

### Follow-Up Audit (2026-05-14)

- [x] Fix pids_limit placement in all 20 compose files (deploy.resources.limits.pids
  per Compose Specification; old placement rejected by Docker Compose v5)
- [x] Fix shellcheck SC2155 in tf.sh (declare and assign separately)
- [x] Fix shellcheck SC3040 in backup scripts (pipefail requires bash, not POSIX sh)
- [x] Fix shellcheck SC2034/SC2046 in run-restore-test.sh (unused var, word splitting)
- [x] Fix terraform fmt in cloudflare.tf and keycloak.tf
- [x] Update OPA policy to check deploy.resources.limits.pids
- [x] Fix documentation: stack counts (20), container counts (74), network architecture
  (3-tier), CrowdSec mode (detection + active blocking), DR runbook tunnel name,
  DR runbook recovery loops (all 20 stacks), DR runbook systemctl reference
- [x] Add 4 missing stacks to service inventory (security, webhook, books,
  project-management)
- [x] Expand CI pipeline documentation in README

---

## Phase 1 -- Production Hardening

### 1.1 Generate and configure second age key [DONE]

Generated recovery age key (public:
`age15e06k0euwx8h4wy6trr7skrwhr2gzkdxgymhjxgkqc2j68tx3rq2d5qk6`).
Added to `.sops.yaml`. All 19 encrypted files re-encrypted with both keys. Recovery
key QR code generated for offline storage. Key deployed to server at
`/root/.config/sops/age/keys.txt`.

### 1.2 Re-enable Cloudflare WAF geo-blocking [BLOCKED]

Code changes done (uncommented `cloudflare_ruleset` in
`terraform/cloudflare.tf:92-142`, blocked CN/RU/KP/IR/SY with Matrix and OIDC
exceptions). Blocked on Cloudflare API token upgrade to include "Zone > Workers
Rulesets > Edit" permission. Operator action required.

### 1.3 Remove ansible-lint `|| true` [DONE]

### 1.4 Remove dead `kc_admin_password` variable [DONE]

---

## Phase 2 -- Reliability and Observability

### 2.1 Migrate Terraform state to remote backend [DOCUMENTED]

`terraform/backend.tf` has three commented options (Terraform Cloud, S3/R2, Git).
Operator must choose one and run `terraform init -migrate-state`.

### 2.2 Add log alerts for remaining services [DONE]

9 total log alert rules across Forgejo, Vaultwarden, Paperless, CrowdSec,
VictoriaLogs, Keycloak, Synapse, Traefik, and OOM events.

### 2.3 Add PostgreSQL slow query monitoring [DONE]

`PostgresSlowQueryRate` alert rule added. `pg_stat_statements` enabled on all 6
PostgreSQL instances:

| Instance | pg_stat_statements | Method |
|----------|-------------------|--------|
| operations-postgres-forgejo | v1.11 | shared_preload_libraries |
| iam-postgres | v1.11 | shared_preload_libraries |
| collaboration-postgres | v1.12 | shared_preload_libraries |
| rss-postgres | v1.10 | shared_preload_libraries |
| photos-postgres | v1.9 | ALTER SYSTEM (alongside vchord.so,vectors.so) |
| documents-postgres | v1.10 | shared_preload_libraries |

### 2.4 Add VictoriaLogs retention policy [ALREADY CONFIGURED]

### 2.5 Fix SARIF upload granularity [DONE]

### 2.6 Add oCIS metrics endpoint to scrape config [DONE]

---

## Phase 3 -- Security Hardening

### 3.1 Add Keycloak auth to Paperless [DONE]

Vaultwarden: NOT APPLICABLE (Bitwarden clients cannot handle OAuth2 redirects).

### 3.2 Evaluate container image signing [DEFERRED]

Re-evaluation scheduled for 2026-Q4. Documented in `docs/infrastructure.md`
Appendix B.

### 3.3 Replace ZFS textfile collector with dedicated exporter [DONE]

Deployed `frebib/zfs-exporter:latest` as `monitoring-zfs-exporter` on port 9254
with `/dev/zfs` device access and `/proc` mount.

---

## Phase 4 -- Automation and CI Improvements

### 4.1 Add Terraform plan as PR comment [DONE]

### 4.2 Add Dependabot for GitHub Actions [DONE]

### 4.3 Add application-level restore tests [DONE]

---

## Phase 5 -- Scalability and Architecture

### 5.1 Multi-node evaluation [DEFERRED]

Single-node with DR runbook (3-6 hour recovery). Revisit if bottleneck.

### 5.2 Restore cAdvisor with tuned metrics [DONE]

cAdvisor v0.49.1 restored with `--disable_metrics=disk,diskIO,tcp,udp,percpu,
perf_event,cpu_topology,cpuset,resctrl,hugetlb,process`. Scrape reduced from ~140MB
to ~45MB. VictoriaMetrics limit increased to 1 GiB.

### 5.3 Add operator onboarding documentation [DONE]

### 5.4 Crash-loop fixes and server reconciliation [DONE]

Fixed three pre-existing crash-loop issues:

| Container | Root Cause | Fix |
|-----------|-----------|-----|
| monitoring-alertmanager | Missing `ntfy-info` receiver in template | Added receiver to alertmanager.yml.tpl |
| monitoring-vmalert | Missing alertmanager dependency | Fixed alertmanager, vmalert recovered |
| collaboration-postgres | Broken `include_dir` quoting in postgresql.conf | Fixed double-quote syntax error |

Server reconciled: all 65 containers now compose-managed, zero manual deployment
drift.

### 5.5 Memory optimization [DONE]

| Action | Memory Freed |
|--------|-------------|
| Disabled Netdata (redundant with VictoriaMetrics + Grafana) | ~770 MiB |
| VictoriaMetrics limit 512M -> 1G | Utilization 73% -> 38% |
| Available memory | 2.2 GiB -> 4.3 GiB |

---

## Phase 6 -- Disaster Recovery (Ongoing)

### 6.1 Quarterly full DR drill [OPERATIONAL]

Next drill: 2026-Q3. Test Scenario 3 (Full Server Recovery) using B2.

### 6.2 Annual secret rotation [DOCUMENTED]

Rotation checklist in `docs/infrastructure.md` Appendix A.

### 6.3 Annual age key rotation test [DOCUMENTED]

Procedure in `docs/disaster-recovery-runbook.md` Scenario 4.

---

## Architecture Evolution Timeline

```text
2026-Q2 (Done)   All roadmap phases implemented
                  - Production hardening, observability, security, CI,
                    scalability, crash-loop fixes, server reconciliation
                  - 65 containers compose-managed, zero drift
                  - ~3 GiB available memory for new services

2026-Q3           Operational maintenance
                  - Quarterly DR drill (6.1)
                  - Cloudflare WAF apply (when token upgraded) (1.2)
                  - Terraform backend migration (operator choice) (2.1)
                  - Container image signing re-evaluation (3.2)

2026-Q4           Infrastructure assessment
                  - Multi-node evaluation if scaling needed (5.1)
                  - Keycloak healthcheck optimization

2027+             Continuous improvement
                  - Annual secret rotation (6.2)
                  - Annual age key rotation test (6.3)
                  - Evaluate Kubernetes if needed
```

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation | Status |
|------|-----------|--------|------------|--------|
| Age key loss | Low | Critical | Second key + QR code offline (1.1) | MITIGATED |
| Unauthorized access via public services | Medium | High | WAF + Keycloak auth (1.2, 3.1) | PARTIAL |
| Terraform state corruption | Low | High | Remote backend (2.1) | DOCUMENTED |
| Undetected application errors | Medium | Medium | Log alerts (2.2) | MITIGATED |
| Database performance degradation | Low | Medium | pg_stat_statements on all 6 instances (2.3) | MITIGATED |
| Log storage fills disk | Low | High | Retention policy 30d (2.4) | MITIGATED |
| Single-node failure | Low | Critical | DR runbook + B2 backup | MITIGATED |
| Compromised container image | Low | High | Trivy daily + version pinning | MITIGATED |
| Renovate auto-merge breakage | Low | Medium | Vetted allowlist (P3-29) | MITIGATED |
| CI pipeline passes broken code | Low | Medium | Comprehensive CI (all jobs) | MITIGATED |

---

## Known Pre-Existing Issues

These issues existed before the audit and are tracked for future resolution:

| Issue | Severity | Notes |
|-------|----------|-------|
| Keycloak healthcheck slow (Java compile) | Low | Functional despite unhealthy status; consider `/health/live` endpoint |
| Forgejo runner healthcheck "can't fork" | Low | System PID limits; runner is operational |
| CADVISOR_VERSION conflict | Low | `versions.env` has v0.49.1, encrypted env has v0.52.1; whichever sourced last wins |

## Post-Roadmap Additions (2026-05-21)

### Completed

- [x] Pin zfs-exporter by digest (no version tags in upstream registry)
- [x] Add `cap_drop: ALL` to collabora with documented justification
- [x] Enhance OPA policy: `deny_logging_no_max_size`, `warn_logging_non_json_file`
- [x] Add cloudflared to `distroless_no_shell_names` exemption list
- [x] Add cloudflared tunnel metrics scrape job (host.docker.internal:4788)
- [x] Add `CloudflaredTunnelDegraded` alert rule
- [x] Investigated Immich, Immich-ML, OAuth2-Proxy metrics: none support
  Prometheus format in current versions (removed non-functional scrape jobs)
- [x] Fix Evergreen pre-push gate: cargo audit `--manifest-path` flag
  not supported in v0.22.1, replaced with `cd evergreenctl && cargo audit`
- [x] Fix 12 pre-existing MD031 markdownlint errors in Evergreen `.specs/`
- [x] Add Evergreen docs: dockerfile-bugs-found.md, sis-deployment-lessons.md,
  metrics endpoint standard (Section 16)
