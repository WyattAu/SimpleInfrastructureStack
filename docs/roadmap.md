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

**Action:**

1. Generate a second age key: `age-keygen -o ~/.config/sops/age/keys-recovery.txt`

2. Add the public key to `.sops.yaml` under `age` recipients (replace the placeholder
   at line 9)

3. Re-encrypt all files: `for f in secrets/*.env.encrypted; do sops updatekeys -y "$f"; done`

4. Store the private key offline: print QR code, store in physical safe AND password
   manager

5. Copy new key to server at `/root/.config/sops/age/keys.txt`

**Verification:** `sops -d secrets/proxy.env.encrypted` succeeds with both keys

### 1.2 Re-enable Cloudflare WAF geo-blocking [HIGH]

**Risk:** No country-level blocking; all services accept global traffic including
automated scanning from CN/RU/KP.

**Action:**

1. Upgrade Cloudflare API token to include Zone.WAF Rulesets permission

2. Uncomment `cloudflare_ruleset` resource in `terraform/cloudflare.tf:92-142`

3. Add exception expressions for Matrix federation and OIDC discovery endpoints

4. Run `terraform plan` to verify, then `terraform apply`

**Verification:** `curl` from a blocked country returns 403

### 1.3 Remove ansible-lint `|| true` [MEDIUM]

**Risk:** Ansible lint violations silently accumulate since CI never fails on them.

**File:** `.github/workflows/validate.yml:300`

**Action:** Remove `|| true` from the ansible-lint step. Fix any existing violations
that surface.

### 1.4 Remove dead `kc_admin_password` variable [LOW]

**File:** `terraform/variables.tf:47`

**Action:** Remove the variable declaration. The service account (terraform-cli)
configured in P3-25 handles all Keycloak operations.

---

## Phase 2 -- Reliability and Observability (Short-Term)

Items that improve uptime monitoring and reduce mean-time-to-detection.

### 2.1 Migrate Terraform state to remote backend [MEDIUM]

**Risk:** Local state has no locking or versioning. Concurrent runs could corrupt state.
Restic backup is up to 24h stale.

**File:** `terraform/backend.tf` (options already documented)

**Action:**

1. Evaluate options: Terraform Cloud (free tier, 500 resources), Cloudflare R2 S3,
  or Git-based backend

2. Configure backend, run `terraform init -migrate-state`

3. Remove local `.tfstate` from Restic backup scope (no longer needed)

### 2.2 Add log alerts for remaining services [MEDIUM]

**File:** `stacks/monitoring/grafana/provisioning/alerting/rules.yml`

**Current:** Keycloak, Synapse, Traefik, OOM (4 alert groups)

**Missing:** Forgejo, Vaultwarden, Immich, Paperless, CrowdSec, VictoriaLogs

**Action:** Add Grafana log alert rules for:

- Forgejo: >20 error responses in 5 minutes
- Vaultwarden: >5 failed login attempts in 5 minutes
- Paperless: >10 consumer errors in 5 minutes
- CrowdSec: >50 scenario triggers in 5 minutes
- VictoriaLogs: ingestion lag >60s

### 2.3 Add PostgreSQL slow query monitoring [MEDIUM]

**Action:**

1. Enable `pg_stat_statements` on all 6 PostgreSQL instances via shared_preload_libraries

2. Add `pg_stat_statements` metrics to postgres-exporter scrape config

3. Add alert: p99 query duration >5s sustained for 5 minutes

4. Add Grafana panel: top 10 slow queries per database

### 2.4 Add VictoriaLogs retention policy [MEDIUM]

**Risk:** Log volume grows unbounded, could fill disk.

**Action:** Configure `-retentionPeriod=30d` flag on VictoriaLogs container.
Add alert for log storage approaching pool capacity (>80%).

### 2.5 Fix SARIF upload granularity [LOW]

**File:** `.github/workflows/vulnerability-scan.yml`

**Issue:** Each matrix job overwrites the previous SARIF file. Only the last scanned
image's results survive.

**Action:** Use unique filenames per stack (`trivy-results-${{ matrix.stack }}.sarif`)
or merge all results into a single file before upload.

### 2.6 Add oCIS metrics endpoint to scrape config [LOW]

**Action:** If oCIS exposes a `/metrics` endpoint, add it to
`stacks/monitoring/victoriametrics/scrape.yml`. If not, document the limitation.

---

## Phase 3 -- Security Hardening (Medium-Term)

### 3.1 Add Keycloak auth to Paperless and Vaultwarden [MEDIUM]

**Risk:** Paperless contains sensitive documents and is publicly accessible behind
rate-limit only.

**Action:**

1. Add Traefik `keycloak-auth` middleware labels to Paperless and Vaultwarden services

2. Configure Keycloak client for each service

3. Test SSO flow: redirect to Keycloak login, then back to service

**Note:** Vaultwarden Bitwarden clients cannot handle OAuth2 redirects natively.
Evaluate whether Keycloak auth via Traefik forwardAuth is compatible with the
Bitwarden API clients (web vault, mobile apps, CLI). If not, keep Vaultwarden
with its built-in auth and only apply Keycloak to Paperless.

### 3.2 Evaluate container image signing [LOW]

**Current:** Not implemented. Mitigated by version pinning + Trivy daily scans.

**Action:** If supply chain risk increases:

1. Generate Cosign key pair

2. Add Cosign verification step to Ansible prepare role

3. Sign images in CI after Trivy scan passes

### 3.3 Replace ZFS textfile collector with dedicated exporter [LOW]

**Current:** Cron-based textfile collector script for ZFS metrics (P2-14).

**Action:** Deploy `fberning/zfs-exporter` or `pdf/zfs_exporter` as a container
for more reliable metrics collection with native Prometheus exposition format.

---

## Phase 4 -- Automation and CI Improvements (Medium-Term)

### 4.1 Add Terraform plan as PR comment [MEDIUM]

**Risk:** DNS/identity changes via Terraform are not reviewed before merge.

**Action:**

1. Add a `terraform-plan` job to `validate.yml` that runs on PRs only

2. Run `terraform plan -no-color -out=tfplan`

3. Post plan output as PR comment using `gh pr comment`

4. Block merge if plan shows destructive changes (unless explicitly approved)

### 4.2 Add Dependabot for GitHub Actions [LOW]

**Action:** Create `.github/dependabot.yml` targeting GitHub Actions versions.
Complements Renovate which handles Docker image updates.

### 4.3 Add application-level restore tests [LOW]

**File:** `stacks/backup/scripts/run-restore-test.sh`

**Current:** Tests file existence and pg_dump validity.

**Action:** Add post-restore application checks:

- Forgejo: verify repo list loads via API
- Paperless: verify document count via API
- Vaultwarden: verify admin token authentication

---

## Phase 5 -- Scalability and Architecture (Long-Term)

### 5.1 Multi-node evaluation [LOW]

**Current constraint:** Single TrueNAS host. Host failure = total outage.

**Mitigation:** DR runbook enables full recovery in 3-6 hours.

**If scaling is needed:**

1. Evaluate Docker Swarm (native, minimal changes to Compose files)

2. Evaluate Kubernetes (significant rearchitecture, full Compose rewrite)

3. Consider splitting services across two hosts (monitoring + apps separation)

4. Add shared storage (NFS/iSCSI) for database persistence across nodes

### 5.2 Replace cAdvisor with Docker metrics plugin [LOW]

**Current:** cAdvisor scrape produces ~140MB, approaching the 160MB limit.

**Action:** Docker Engine 20.10+ exposes metrics natively on `:9323/metrics`.
Replace cAdvisor with the built-in metrics endpoint. Reduces scrape size by ~60%.

### 5.3 Add operator onboarding documentation [LOW]

**Action:** Create `docs/onboarding.md` covering:

1. Repository structure overview

2. How to add a new stack (step-by-step)

3. How to update a secret

4. How to read monitoring dashboards

5. How to troubleshoot a failed deploy

6. Emergency contacts and escalation paths

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

**Action:** Implement the rotation schedule from `docs/infrastructure.md` Appendix A:

- Cloudflare API token: annually
- Keycloak client secrets: annually
- Database passwords: annually
- Age encryption key: emergency only (with full re-encryption)

### 6.3 Annual age key rotation test [MEDIUM]

**Action:** Test the age key rotation procedure:

1. Generate new key

2. Re-encrypt all 20 secret files

3. Verify decryption works with new key only

4. Verify deployment pipeline works with new key

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
| Age key loss | Low | Critical | Second key (1.1) | OPEN |
| Unauthorized access via public services | Medium | High | WAF + Keycloak auth (1.2, 3.1) | PARTIAL |
| Terraform state corruption | Low | High | Remote backend (2.1) | OPEN |
| Undetected application errors | Medium | Medium | Log alerts (2.2) | PARTIAL |
| Database performance degradation | Low | Medium | pg_stat_statements (2.3) | OPEN |
| Log storage fills disk | Medium | High | Retention policy (2.4) | OPEN |
| Single-node failure | Low | Critical | DR runbook + B2 backup | MITIGATED |
| Compromised container image | Low | High | Trivy daily + version pinning | MITIGATED |
| Renovate auto-merge breakage | Low | Medium | Vetted allowlist (P3-29) | MITIGATED |
| CI pipeline passes broken code | Low | Medium | Comprehensive CI (all jobs) | MITIGATED |
