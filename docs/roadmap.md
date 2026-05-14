# SimpleInfrastructureStack -- Roadmap

Comprehensive improvement plan derived from two full monorepo audits (2026-05-11
initial, 2026-05-14 follow-up). The audits covered: 20 Docker Compose stacks,
7 Ansible playbooks, 4 CI/CD workflows, 68 Terraform resources, 1 OPA policy,
5 documentation files, and all shell scripts.

---

## Current State

### Test Results (2026-05-14)

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
| Containers | 74 (including init containers) |
| Networks | 3 (traefik_net, backend_net, data_net) |
| PostgreSQL instances | 6 |
| Terraform resources | 68 |
| OPA DENY rules | 9 |
| OPA WARN rules | 6 |
| Grafana dashboards | 10 |
| Alert rule groups | 20+ |
| SOPS-encrypted files | 20 |

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

## Phase 1 -- Production Hardening (Immediate)

Items that reduce risk of security incidents or data loss.

### 1.1 Generate and configure second age key [CRITICAL]

**Risk:** Single age key protects all 20 encrypted files. Loss = total secrets loss.

**Status:** DONE (code changes). Pending: deploy recovery key to server, re-encrypt all
20 files with `sops updatekeys -y`.

**Action completed:**

1. Generated recovery age key (public: `age15e06k0euwx8h4wy6trr7skrwhr2gzkdxgymhjxgkqc2j68tx3rq2d5qk6`)
2. Added to `.sops.yaml` under `age` recipients
3. Re-encrypt all files: `for f in secrets/*.env.encrypted; do sops updatekeys -y "$f"; done`
4. Store the private key offline: print QR code, store in physical safe AND password
   manager
5. Copy new key to server at `/root/.config/sops/age/keys.txt`

**Verification:** `sops -d secrets/proxy.env.encrypted` succeeds with both keys

### 1.2 Re-enable Cloudflare WAF geo-blocking [HIGH]

**Risk:** No country-level blocking; all services accept global traffic including
automated scanning from CN/RU/KP.

**Status:** DONE (code changes). Pending: upgrade Cloudflare API token to include
"Zone > Workers Rulesets > Edit" permission, then `terraform apply`.

**Action completed:**

1. Uncommented `cloudflare_ruleset` resource in `terraform/cloudflare.tf:92-142`
2. Added exception expressions for Matrix federation and OIDC discovery endpoints
3. Blocked countries: CN, RU, KP, IR, SY

**Remaining:** Upgrade Cloudflare API token permission, run `terraform plan` and `terraform apply`

**Verification:** `curl` from a blocked country returns 403

### 1.3 Remove ansible-lint `|| true` [MEDIUM]

**Risk:** Ansible lint violations silently accumulate since CI never fails on them.

**Status:** DONE. Removed `|| true` from `.github/workflows/validate.yml`. No existing violations.

**File:** `.github/workflows/validate.yml`

### 1.4 Remove dead `kc_admin_password` variable [LOW]

**Status:** DONE. Removed `kc_admin_username`, `kc_admin_password`, `kc_base_url`
variables from `terraform/variables.tf`. Hardcoded Keycloak provider URL in
`terraform/keycloak.tf`. Updated `scripts/tf.sh` to use `KC_SA_CLIENT_SECRET`.

**Files:** `terraform/variables.tf`, `terraform/keycloak.tf`, `scripts/tf.sh`

---

## Phase 2 -- Reliability and Observability (Short-Term)

Items that improve uptime monitoring and reduce mean-time-to-detection.

### 2.1 Migrate Terraform state to remote backend [MEDIUM]

**Risk:** Local state has no locking or versioning. Concurrent runs could corrupt state.
Restic backup is up to 24h stale.

**Status:** DOCUMENTED. `terraform/backend.tf` has three commented options (Terraform
Cloud, S3/R2, Git). Operator must choose one and run `terraform init -migrate-state`.

**File:** `terraform/backend.tf` (options already documented)

### 2.2 Add log alerts for remaining services [MEDIUM]

**File:** `stacks/monitoring/grafana/provisioning/alerting/rules.yml`

**Status:** DONE. Added 5 new log alert rules:

- Forgejo: >20 error responses in 5 minutes
- Vaultwarden: >5 failed login attempts in 5 minutes
- Paperless: >10 consumer errors in 5 minutes
- CrowdSec: >50 scenario triggers in 5 minutes
- VictoriaLogs: ingestion lag events

**Total log alerts:** 9 (was 4)

### 2.3 Add PostgreSQL slow query monitoring [MEDIUM]

**Status:** DONE. Added `database_performance` alert group to
`stacks/monitoring/prometheus/alert_rules.yml` with `PostgresSlowQueryRate` alert
(p99 >5s sustained for 10 minutes).

**Files:** `stacks/monitoring/prometheus/alert_rules.yml`

**Remaining:** Enable `pg_stat_statements` on PostgreSQL instances via
shared_preload_libraries (server-side config change). Add Grafana panel for top 10
slow queries.

### 2.4 Add VictoriaLogs retention policy [MEDIUM]

**Risk:** Log volume grows unbounded, could fill disk.

**Status:** ALREADY CONFIGURED. VictoriaLogs already has `--retentionPeriod=30d`.
No code change needed.

### 2.5 Fix SARIF upload granularity [LOW]

**File:** `.github/workflows/vulnerability-scan.yml`

**Status:** DONE. SARIF filenames now include stack name
(`trivy-results-${{ matrix.stack }}.sarif`) so each image's results survive upload.

### 2.6 Add oCIS metrics endpoint to scrape config [LOW]

**Status:** DONE. oCIS exposes `/metrics` on port 9200. Added `ocis` scrape job to
`stacks/monitoring/victoriametrics/scrape.yml` targeting `storage-ocis:9200` at 30s
interval.

**Files:** `stacks/monitoring/victoriametrics/scrape.yml`

---

## Phase 3 -- Security Hardening (Medium-Term)

### 3.1 Add Keycloak auth to Paperless and Vaultwarden [MEDIUM]

**Risk:** Paperless contains sensitive documents and is publicly accessible behind
rate-limit only.

**Status:** DONE (Paperless). Added `keycloak-auth` middleware to Paperless Traefik
labels in `stacks/documents/docker-compose.yml`. Added Paperless redirect URI to
Keycloak OIDC client in `terraform/keycloak.tf`.

Vaultwarden: NOT APPLICABLE. Bitwarden API clients (web vault, mobile apps, CLI)
cannot handle OAuth2 redirects. Vaultwarden keeps its built-in auth.

**Files:** `stacks/documents/docker-compose.yml`, `terraform/keycloak.tf`

### 3.2 Evaluate container image signing [LOW]

**Status:** DEFERRED (2026-Q2). Current mitigation stack (version pinning + daily
Trivy scanning + Renovate + OPA enforcement) provides sufficient supply chain
security for single-operator homelab. Re-evaluation scheduled for 2026-Q4.
Documented in `docs/infrastructure.md` Appendix B.

### 3.3 Replace ZFS textfile collector with dedicated exporter [LOW]

**Status:** DONE. Deployed `fberning/zfs-exporter:0.0.12` as `monitoring-zfs-exporter`
container in monitoring compose. Host root mounted at `/hostroot:ro` with
`no-new-privileges` and `cap_drop: ALL`. Added `zfs-exporter` scrape job to
`stacks/monitoring/victoriametrics/scrape.yml` targeting `:9854` at 60s interval.

**Files:** `stacks/monitoring/docker-compose.yml`,
`stacks/monitoring/victoriametrics/scrape.yml`

---

## Phase 4 -- Automation and CI Improvements (Medium-Term)

### 4.1 Add Terraform plan as PR comment [MEDIUM]

**Risk:** DNS/identity changes via Terraform are not reviewed before merge.

**Status:** DONE. Added `terraform-plan` job to `.github/workflows/validate.yml`
(PR-only). Runs `terraform plan -no-color` and posts output as PR comment.

**File:** `.github/workflows/validate.yml`

### 4.2 Add Dependabot for GitHub Actions [LOW]

**Status:** DONE. Created `.github/dependabot.yml` with weekly GitHub Actions update
checks (Mondays 03:00 UTC). Complements Renovate which handles Docker image updates.

### 4.3 Add application-level restore tests [LOW]

**File:** `stacks/backup/scripts/run-restore-test.sh`

**Status:** DONE. Added post-restore application verification step:

- Forgejo: verify config loads via `forgejo dump-config`
- Paperless: verify database has documents via `psql` count query

**Files:** `stacks/backup/scripts/run-restore-test.sh`

---

## Phase 5 -- Scalability and Architecture (Long-Term)

### 5.1 Multi-node evaluation [LOW]

**Current constraint:** Single TrueNAS host. Host failure = total outage.

**Status:** DEFERRED. Documentation/assessment only. No code changes needed.
DR runbook enables full recovery in 3-6 hours. Revisit if single-node becomes a
bottleneck.

### 5.2 Replace cAdvisor with Docker metrics plugin [LOW]

**Status:** DONE. Removed cAdvisor service (41 lines) from monitoring compose.
Replaced cAdvisor scrape job with Docker metrics job targeting
`monitoring-node-exporter:9323` at 60s interval. Requires Docker Engine
`metrics-addr` configured to expose metrics on that port (server-side config).

**Files:** `stacks/monitoring/docker-compose.yml`,
`stacks/monitoring/victoriametrics/scrape.yml`

### 5.3 Add operator onboarding documentation [LOW]

**Status:** DONE. Created `docs/onboarding.md` covering:

1. Repository structure overview
2. How to add a new stack (step-by-step)
3. How to update a secret
4. How to read monitoring dashboards
5. How to troubleshoot a failed deploy
6. Emergency contacts and escalation paths

**File:** `docs/onboarding.md`

---

## Phase 6 -- Disaster Recovery (Ongoing)

### 6.1 Quarterly full DR drill [HIGH]

**Action:** Schedule a quarterly test of the disaster-recovery-runbook:

1. Spin up a test VM with TrueNAS SCALE

2. Follow Scenario 3 (Full Server Recovery) using B2 as source

3. Verify all 74 containers start and pass health checks

4. Verify SSO login works via Keycloak

5. Verify backup/restore pipeline works on the new host

6. Document any issues found, update runbook

### 6.2 Annual secret rotation [MEDIUM]

**Status:** DOCUMENTED. Added Automated Rotation Checklist table to
`docs/infrastructure.md` Appendix A covering 7 secret types with rotation method
and frequency.

### 6.3 Annual age key rotation test [MEDIUM]

**Status:** DOCUMENTED. Added Age Key Rotation Test Procedure to
`docs/disaster-recovery-runbook.md` Scenario 4 with 6-step verification process
(generate, re-encrypt, verify decrypt, verify deploy, verify backup, secure old key).

---

## Architecture Evolution Timeline

```text
2026-Q2 (Now)     Phase 1-2: Production hardening + observability
                  - Second age key, WAF geo-blocking, log alerts, PG monitoring

2026-Q3           Phase 3-4: Security hardening + CI improvements
                  - Keycloak auth for Paperless, Terraform plan reviews,
                    image signing evaluation

2026-Q4           Phase 5: Scalability evaluation
                  - Multi-node assessment, cAdvisor replacement,
                    operator onboarding docs

2027+             Phase 6: Continuous improvement
                  - Quarterly DR drills, annual secret rotation,
                    evaluate Kubernetes if needed
```

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation | Status |
|------|-----------|--------|------------|--------|
| Age key loss | Low | Critical | Second key (1.1) | PARTIAL |
| Unauthorized access via public services | Medium | High | WAF + Keycloak auth (1.2, 3.1) | PARTIAL |
| Terraform state corruption | Low | High | Remote backend (2.1) | DOCUMENTED |
| Undetected application errors | Medium | Medium | Log alerts (2.2) | MITIGATED |
| Database performance degradation | Low | Medium | pg_stat_statements (2.3) | PARTIAL |
| Log storage fills disk | Low | High | Retention policy (2.4) | MITIGATED |
| Single-node failure | Low | Critical | DR runbook + B2 backup | MITIGATED |
| Compromised container image | Low | High | Trivy daily + version pinning | MITIGATED |
| Renovate auto-merge breakage | Low | Medium | Vetted allowlist (P3-29) | MITIGATED |
| CI pipeline passes broken code | Low | Medium | Comprehensive CI (all jobs) | MITIGATED |
