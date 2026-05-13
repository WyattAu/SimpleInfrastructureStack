# SimpleInfrastructureStack -- Roadmap

Comprehensive improvement plan derived from a full monorepo audit (2026-05-11).
The audit covered: 19 Docker Compose stacks, 7 Ansible playbooks, 4 CI/CD workflows,
68 Terraform resources, 1 OPA policy, 3 documentation files, and all shell scripts.

---

## Audit Summary

### What Was Tested

| Check | Tool | Result |
|-------|------|--------|
| Trailing whitespace | pre-commit-hooks | PASS |
| End-of-file fixer | pre-commit-hooks | PASS (fixed terraform/.gitignore) |
| YAML syntax | check-yaml | PASS |
| JSON syntax | check-json | PASS |
| Merge conflicts | check-merge-conflict | PASS |
| Large files | check-added-large-files | PASS |
| Markdown lint | markdownlint-cli2 v0.18.1 | PASS (91 errors fixed) |
| YAML lint | yamllint v1.37.1 | PASS (30 document-start, 2 brace, comment fixes) |
| Docker Compose config | docker compose config | PASS (19/19 stacks) |
| Ansible syntax | ansible-playbook --syntax-check | PASS (6/6 playbooks) |
| Terraform validate | terraform validate | SKIP (providers not cached locally) |

### What Was Fixed (Commit 463c9b4)

- 91 markdownlint errors across 6 files (MD022, MD026, MD031, MD032, MD034, MD040)
- Missing `---` document-start markers in 30 YAML files
- yamllint brace spacing errors in Grafana datasources
- Comment spacing issues across 7 compose/config files
- Invalid webhook volume spec (empty `SOPS_AGE_KEY_DIR`)
- Emoji indicators replaced with text labels in CI workflows
- Commented-out prettier hook removed from pre-commit config
- Makefile `format` target fixed (was referencing disabled prettier hook)

---

## Priority 0 -- Critical (Security/Correctness)

### 1. Fix compose validation exit code bug

**File:** `.github/workflows/validate.yml:53-71`

The compose validation loop sets `FAILED=0` at the top but the `else` branch
(where compose config fails) only runs `echo`, never sets `FAILED=1`. The
`exit $FAILED` at line 71 always exits 0, meaning compose validation never fails
the CI pipeline even when stacks are broken.

**Fix:** Add `FAILED=1` inside the else branch.

### 2. Re-enable Cloudflare WAF geo-blocking

**File:** `terraform/cloudflare.tf:94-145`

The entire geo-blocking ruleset (CN, RU, KP, IR, SY) is commented out because
the Cloudflare API token lacks `Zone.WAF` permissions. Documentation at
`docs/infrastructure.md` line 260 still claims geo-blocking is active.

**Fix:** Either upgrade the API token permissions and uncomment the ruleset, or
update the documentation to reflect that geo-blocking is disabled.

### 3. Add second age key for secret redundancy

**File:** `.sops.yaml`

A single age key protects all 17 encrypted secret files. Loss of this key makes
all secrets unrecoverable. The DR runbook recommends storing a physical backup
but there is no second key in the configuration.

**Fix:** Generate a second age key, add it to `.sops.yaml` under `age` recipients,
store the second key offline (physical safe, password manager).

### 4. Fix DR runbook Restic repository path

**File:** `docs/disaster-recovery-runbook.md:88`

The runbook references `/backup/repo` but the actual mount in
`stacks/backup/docker-compose.yml:18` is `/restic-repo`. Following the runbook
during an emergency would fail.

**Fix:** Replace all instances of `/backup/repo` with `/restic-repo`.

### 5. Add conftest OPA policy check to CI

**File:** `.github/workflows/validate.yml`

The documentation at `docs/runbook.md:301` lists "OPA policy check (security.rego)"
as step 3 of CI, but no conftest step exists in the workflow. The policy exists
at `policies/docker-compose/security.rego` but is never validated.

**Fix:** Add a conftest step to the compose-validate job (conftest is already
installed at line 26).

---

## Priority 1 -- High (Hardening/Reliability)

### 6. Add `cap_drop: ALL` to socket-proxy and forgejo-runner

**Files:** `stacks/proxy/docker-compose.yml`, `stacks/operations/docker-compose.yml`

`proxy-socket-proxy` only has `cap_add: NET_RAW` without `cap_drop: ALL`.
`operations-forgejo-runner` has no `cap_drop` at all. Both containers inherit
Docker's default capability set, which includes `CHOWN`, `DAC_OVERRIDE`,
`SETUID`, `SETGID`, and others.

**Fix:** Add `cap_drop: [ALL]` to both services (keep existing `cap_add`).

### 7. Add pre-backup database dumps

**File:** `stacks/backup/scripts/run-backup.sh`

Current backups use raw file copies of PostgreSQL data directories. If a database
is mid-write during backup, restored files could be corrupted (WAL replay may
fail). Six PostgreSQL instances are affected (Forgejo, Keycloak, Synapse,
FreshRSS, Immich, Paperless).

**Fix:** Add `docker exec <container> pg_dump -Fc` before the Restic backup
for each PostgreSQL instance. Dump files should be written to a temporary
location included in the backup scope.

### 8. Add Terraform validation to CI

**File:** `.github/workflows/validate.yml`

No `terraform fmt -check`, `terraform validate`, or `tflint` runs in CI.
Terraform syntax errors are only discovered at deploy time.

**Fix:** Add a `terraform-validate` job with `hashicorp/setup-terraform` action,
`terraform fmt -check -recursive`, and `terraform validate`.

### 9. Add secret scanning to CI

**File:** `.github/workflows/validate.yml`

No `gitleaks` or `trufflehog` step exists. The `infra_secrets_path` in
`ansible/inventory/group_vars/all.yml:14` points inside the git repo (`.secrets.tmp/`),
creating risk of accidental secret commits.

**Fix:** Add `gitleaks` scan step. Move `infra_secrets_path` to `/tmp/sis-secrets/`
or another path outside the repository.

### 10. Add `ansible-lint` to CI

**File:** `.github/workflows/validate.yml`

Only `ansible-playbook --syntax-check` runs. No best-practice linting for
deprecated modules, shell without pipefail, or idempotency issues.

**Fix:** Add `ansible-lint` to the ansible-check job.

### 11. Add shellcheck for shell scripts

**Files:** `stacks/backup/scripts/*.sh`, `stacks/webhook/*.sh`

Seven shell scripts have no static analysis. Common issues include unquoted
variables, missing `set -euo pipefail`, and command injection vectors.

**Fix:** Add a shellcheck step to validate.yml targeting all `.sh` files.

### 12. Add SARIF upload for vulnerability scans

**File:** `.github/workflows/vulnerability-scan.yml`

The workflow has `security-events: write` permission but never uploads SARIF
results to the GitHub Security tab. Trivy supports `--format sarif`.

**Fix:** Add `github/codeql-action/upload-sarif@v3` step after Trivy scans.

### 13. Resolve SMTP provider documentation discrepancy

**Files:** `docs/runbook.md:283`, `terraform/variables.tf:64`

Runbook says SMTP2GO (`mail.smtp2go.com:2525`) but Terraform defaults to
`smtp.protonmail.ch:587`. Only one can be correct.

**Fix:** Verify which provider is in use and update the incorrect reference.

---

## Priority 2 -- Medium (Observability/Maintainability)

### 14. Add ZFS pool metrics to monitoring

**File:** `stacks/monitoring/victoriametrics/scrape.yml`

Running on TrueNAS with ZFS, but no ZFS pool health, scrub status, or dataset
usage metrics are collected. TrueNAS exposes metrics via its API or via
`zpool status`/`zfs list`.

**Fix:** Add a ZFS exporter (e.g., `fberning/zfs-exporter` or a textfile
collector script run via cron) and create a ZFS health dashboard.

### 15. Add log-based alerting

**File:** `stacks/monitoring/grafana/provisioning/alerting/rules.yml`

VictoriaLogs collects logs but there are no log-based alert rules. Keycloak
failed login spikes, Traefik 5xx rate bursts, and application error patterns
go undetected until they cause metric-level alerts.

**Fix:** Add VictoriaLogs alert rules for:

- Keycloak: >10 failed login attempts in 5 minutes
- Traefik: >50 5xx responses in 5 minutes
- General: any `level=error` spike >100 in 5 minutes

### 16. Add backup size monitoring

**File:** `stacks/backup/scripts/run-backup.sh`

Backup duration is tracked but not backup size. A sudden drop in backup size
(e.g., from 30GB to 5GB) would indicate data loss but go undetected.

**Fix:** Add `sis_backup_size_bytes` metric to the textfile collector. Add an
alert for >50% size decrease between consecutive backups.

### 17. Add database integrity to restore tests

**File:** `stacks/backup/scripts/run-restore-test.sh`

The monthly restore test only checks file existence and non-empty content. A
corrupted PostgreSQL data directory that is non-empty would pass.

**Fix:** After file restore, run `docker exec <postgres> pg_isready` and
optionally `pg_dump --validate` for each database.

### 18. Template Alertmanager ntfy URLs

**File:** `stacks/monitoring/alertmanager/alertmanager.yml:31-36`

The ntfy topic URLs are hardcoded in plaintext. While ntfy topics are not
secret, the topic names leak infrastructure naming conventions.

**Fix:** Convert to Jinja2 template (`alertmanager.yml.tmpl`) and inject
topic URLs from SOPS secrets, consistent with the Grafana contact-points pattern.

### 19. Add `pids_limit` to all long-running containers

**Files:** All `stacks/*/docker-compose.yml`

No container has a PID limit. A fork bomb inside any container could crash
the host by exhausting the PID table.

**Fix:** Add `pids_limit: 100` (or appropriate value) to all services.
Add a WARN rule to `security.rego`.

### 20. Add `no-new-privileges:true` to WireGuard

**File:** `stacks/vpn/docker-compose.yml`

WireGuard runs in privileged mode (exempt from OPA policy) but lacks
`no-new-privileges:true`. While privileged mode implies all capabilities,
`no-new-privileges` prevents setuid binaries from further escalating.

**Fix:** Add `security_opt: [no-new-privileges:true]` to the VPN service.

### 21. Add CPU limits to memory-heavy containers

**Files:** `stacks/collaboration/docker-compose.yml`, `stacks/photos/docker-compose.yml`

Only 3 containers have CPU limits (backup-restic, forgejo, forgejo-runner).
Memory-heavy containers like Synapse (8GB) and Immich (1GB) have no CPU limit.

**Fix:** Add `cpus: 2.0` to Synapse, `cpus: 1.0` to Immich server, and evaluate
other memory-intensive services.

---

## Priority 3 -- Low (Nice-to-Have)

### 22. Add `read_only:true` OPA WARN rule

**File:** `policies/docker-compose/security.rego`

Only `backup-restic` and `proxy-well-known-server` use `read_only: true`.
A WARN rule would encourage wider adoption.

### 23. Add `user:` directive OPA WARN rule

**File:** `policies/docker-compose/security.rego`

Most containers run as root. A WARN rule for containers without explicit `user:`
would improve hygiene for non-database services.

### 24. Add Terraform remote state backend

**File:** `terraform/main.tf`

State is stored locally and backed up via Restic (up to 24h stale). A remote
backend (Terraform Cloud, GitLab) would provide locking, versioning, and
immediate availability.

### 25. Create dedicated Keycloak service account for Terraform

**File:** `terraform/keycloak.tf:5-11`

Terraform authenticates as `admin-cli` with the admin password. A dedicated
service account with minimal permissions (realm read, client management) would
limit blast radius.

### 26. Add Keycloak user `ignore_changes` for credentials

**File:** `terraform/keycloak.tf:98-137`

Only the `viswa` user has `ignore_changes = [required_actions]`. All users
should also ignore `credentials` to prevent Terraform from resetting passwords.

### 27. Remove Cloudflare zone/account ID defaults

**File:** `terraform/variables.tf:16-32`

`cf_zone_id` and `cf_account_id` have default values. These should be required
(with no defaults) to prevent accidentally targeting the wrong zone.

### 28. Add GitHub Actions tool caching

**File:** `.github/workflows/validate.yml`

conftest, yamllint, ansible-core, and trivy are installed fresh every run.
Caching pip packages and binary downloads would reduce CI runtime by 30-60s.

### 29. Evaluate Renovate auto-merge policy

**File:** `renovate.json5:22-28`

Auto-merge is enabled for minor/patch Docker updates. For 62 containers, an
auto-merged breaking change could cascade across multiple services. Consider
restricting auto-merge to a vetted image allowlist.

### 30. Add CODEOWNERS file

**File:** `.github/CODEOWNERS` (missing)

No CODEOWNERS file exists. Critical paths (terraform/, ansible/, policies/)
should require review from designated owners.

### 31. Add markdown link checking to CI

**Files:** `docs/*.md`

Internal links between documentation files are not validated. Broken links
accumulate silently.

**Fix:** Add `markdown-link-check` to validate.yml.

---

## Completed (This Audit)

### Initial Audit (Commit 463c9b4)

- [x] All pre-commit hooks pass (trailing-whitespace, end-of-file-fixer, check-yaml, check-json, check-merge-conflict, check-added-large-files, markdownlint-cli2, yamllint)
- [x] All 19 Docker Compose stacks validate with `docker compose config`
- [x] All 6 Ansible playbooks pass syntax check
- [x] 91 markdownlint errors fixed across 6 documentation files
- [x] 30 YAML files updated with document-start markers
- [x] yamllint errors and warnings resolved
- [x] Webhook compose volume spec fixed
- [x] CI workflow emojis replaced with text labels
- [x] Dead prettier hook reference removed
- [x] Makefile format target fixed

### Roadmap Implementation (Commit 5ee9521+)

- [x] P0-1: Fix compose validation exit code bug in validate.yml
- [x] P0-2: Document Cloudflare WAF geo-blocking as disabled, add SECURITY NOTE
- [x] P0-3: Add recovery key placeholder and documentation to .sops.yaml
- [x] P0-4: Fix DR runbook Restic path (/backup/repo -> /restic-repo)
- [x] P0-5: Add conftest OPA policy check step to CI
- [x] P1-6: Add cap_drop: ALL to socket-proxy and forgejo-runner
- [x] P1-7: Add pre-backup pg_dump for all 6 PostgreSQL instances
- [x] P1-8: Add Terraform fmt/init/validate job to CI
- [x] P1-9: Add gitleaks secret scanning job to CI
- [x] P1-10: Add ansible-lint job to CI
- [x] P1-11: Add shellcheck job to CI
- [x] P1-12: Add SARIF upload for Trivy vulnerability scans
- [x] P1-13: Fix SMTP provider discrepancy (terraform defaults now match runbook)
- [x] P2-15: Log-based alerting already exists (Keycloak, Synapse, Traefik, OOM)
- [x] P2-16: Add backup size metric (sis_backup_size_bytes) and alert
- [x] P2-17: Add dump file verification to monthly restore test
- [x] P2-20: Add no-new-privileges:true to WireGuard VPN
- [x] P2-18: Template Alertmanager ntfy URLs via envsubst entrypoint wrapper
- [x] P2-19: Add pids_limit:100 to all 58 long-running containers
- [x] P2-21: Add CPU limits to all memory-heavy containers
- [x] P3-22: Add read_only:true WARN rule to security.rego
- [x] P3-23: Add user directive and cap_drop WARN rules to security.rego
- [x] P3-26: Add ignore_changes=[credentials] to all Keycloak user resources
- [x] P3-27: Remove hardcoded defaults from cf_zone_id and cf_account_id
- [x] P3-28: Add GitHub Actions caching for conftest, trivy, pip
- [x] P3-29: Restrict Renovate auto-merge to vetted image allowlist
- [x] P3-30: Add CODEOWNERS file
- [x] P3-31: Add markdown-link-check job to validate.yml
- [x] P2-14: Add ZFS pool metrics (textfile collector script + alert rules)
- [x] P3-24: Add Terraform remote state backend configuration (backend.tf with S3/TFC/git options)
- [x] P3-25: Configure Keycloak dedicated service account (terraform-cli) in provider
- [x] CI workflow emojis replaced with text labels
- [x] Dead prettier hook reference removed
- [x] Makefile format target fixed
- [x] Changes committed (463c9b4) and pushed to main
