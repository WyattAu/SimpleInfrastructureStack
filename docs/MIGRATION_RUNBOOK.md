# SimpleInfrastructureStack — Major-Version Migration Runbook

> Status: PREPARED, NOT EXECUTED. Servers are down; execute in a scheduled
> maintenance window. No version values have been bumped — this document is the
> plan. Prepared 2026-09-28 against `main` (EIR registry state verified same day).

This is the single source of truth for pending major-version bumps and for the
bumps already completed. Execute top to bottom: pre-flight, then stacks in the
order below, then post-window tasks.

Deployment mechanic for every stack: edit files, commit to `main`, push, then
run `./scripts/deploy.sh` (mirrors the Ansible pipeline: SOPS decrypt, template
expand, `docker compose up` per stack in dependency order, health-check poll
with 15 min/container timeout, automatic git rollback + redeploy on failure).
The auto-deploy webhook path is acceptable when it is back.

The golden rule: `versions.env` does **not** change what runs. Most compose
files hardcode image tags; `versions.env` is the Renovate-tracked inventory.
Every bump edits **both** `stacks/<stack>/versions.env` **and**
`stacks/<stack>/docker-compose.yml` in one commit, plus `versions.digests` for
upstream (non-EIR) images — see the synapse bump commit `86263e3` for the
pattern.

## Pending majors at a glance

| Order | Stack | Component | Deployed | Target | Migration class | Blocker |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | iam | Keycloak | 26.6.2 | 26.7.3 | In-place restart (minor within major 26) | EIR image build required |
| 2 | storage | Collabora Online (CODE) | 25.04.9.4.1 | 26.04.1.4.1 | In-place restart + proxy/healthcheck review | EIR image build required |
| 3 | documents | Paperless-ngx | 2.20.15 | 3.1.3 | Migration required (one-way DB/search migrations) | EIR image build required |
| 4 | photos | Immich | v2.7.5 | latest v3.x | Migration required (one-way DB migration at startup) | None — upstream images |

EIR registry check (2026-09-28): `ghcr.io/wyattau/evergreenimageregistry` holds
only `keycloak:26.6.2`, `collabora-online:25.04.9.4.1`, `paperless-ngx:2.20.15`.
Immich is unaffected: its compose uses upstream images
(`ghcr.io/immich-app/*`) directly.

## Execution order, dependencies, and window estimates

Keycloak goes first: it is the auth hub. `oauth2-proxy` (proxy stack) validates
against `https://auth.<domain>/realms/company-realm` and its `keycloak-auth@file`
Traefik middleware gates homepage, traefik dashboard, kuma, prometheus,
akaunting, forgejo, taiga, books, ocis (cloud), and paperless. Grafana, ocis,
forgejo, and ferro hold direct OIDC clients on the same realm. Every later
validation step in this window depends on Keycloak being healthy.

1. **iam-keycloak — 30–45 min.** Nothing may authenticate against Keycloak
   while it migrates; schedule at window start. Postgres 17.10 sidecar is
   untouched.
2. **storage-collabora — 30–45 min.** Validated by opening a document through
   ocis, so it follows Keycloak. Stateless (no volumes) — cheapest rollback in
   the window.
3. **documents-paperless — 60–120 min.** Login is gated by
   `keycloak-auth@file` (validated in step 1). The one-way migration
   (Whoosh-to-Tantivy index rebuild) scales with corpus size; the compose
   healthcheck already allows `start_period: 600s`.
4. **photos-immich — 60–120 min.** Independent of Keycloak (public route). The
   v3 startup migration and ML reindexing scale with library size; do not
   truncate this slot.

Total window: 3–4.5 h plus contingency. EIR image builds happen **before** the
window (they are CI work in the EvergreenImageRegistry repo), not inside it.

## Pre-flight checklist

All commands are in-repo scripts or the repo containers' own entrypoints. Run
on TrueNAS (where the Docker socket and restic repo live), not from a laptop.

- [ ] Working tree clean, `main` up to date (`git pull --ff-only` locally;
      `deploy.sh` does its own fetch/reset on the server).
- [ ] EIR images exist for all three blocked targets (Docker CLI):

  ```bash
  docker manifest inspect ghcr.io/wyattau/evergreenimageregistry/keycloak:26.7.3
  docker manifest inspect ghcr.io/wyattau/evergreenimageregistry/collabora-online:26.04.1.4.1
  docker manifest inspect ghcr.io/wyattau/evergreenimageregistry/paperless-ngx:3.1.3
  ```

  Any failure = build the EIR image first and re-check; do not improvise tags.
- [ ] Fresh backup **and** offsite sync. Run the repo backup script
  (`stacks/backup/scripts/backup.sh`, deployed at
  `/mnt/pool_HDD_x2/infra/stacks/stacks/backup/scripts/backup.sh`): it dumps
  every database (`immich.sql`, `paperless.sql`, `keycloak.sql`, `forgejo.sql`,
  `synapse.sql`, `headscale.sql`, `erpnext.sql`, `vaultwarden.sqlite3`), takes
  per-stack tagged restic snapshots, prunes, runs `restic check`, and copies to
  Backblaze B2. Alternative in-container flow:
  `docker exec backup-cron-trigger /scripts/run-backup.sh`
  (`stacks/backup/scripts/run-backup.sh` — `pg_dump -Fc` per DB + full `/data`
  snapshot + retention + restore-verify).
- [ ] Backup verified fresh:

  ```bash
  sudo docker exec backup-restic restic snapshots --latest 1 --compact
  ```

  (same invocation as the `backup-restic` compose healthcheck). Offsite age is
  also exported as `sis_backup_offsite_last_success` and alerted by
  `BackupOffsiteSyncStale`.
- [ ] Restore path rehearsed: `stacks/backup/scripts/run-restore-test.sh`
  restores the latest snapshot per critical tag (`operations`, `iam`,
  `vaultwarden`, `monitoring`, `configs`, `db-dumps`) into a temp dir and
  validates contents. It must pass before touching volumes.
- [ ] Keycloak realm export refreshed so the JSON in the backup is current:
  `docker exec backup-cron-trigger /scripts/run-keycloak-export.sh`
  (`stacks/backup/scripts/run-keycloak-export.sh` — same invocation its cron
  entry uses). Confirm
  `/mnt/pool_HDD_x2/tank/datasources/sis/appdata/iam/realm-export/company-realm-export.json`
  changed and is not the `export_error` marker.
- [ ] Digest baseline green: `./scripts/verify-digests.sh` (reads
  `versions.digests`, compares running images; EIR builds
  `ghcr.io/wyattau/*` are skipped by design). Fix failures before adding new
  variables.
- [ ] Vulnerability baseline: GitHub Actions **Vulnerability Scan** workflow
  (`.github/workflows/vulnerability-scan.yml`, daily 04:00 UTC, Trivy
  HIGH/CRITICAL, SARIF to Security tab) is green on `main`; the weekly host
  cron scan (`scripts/vuln-scan.sh`, Trivy via
  `aquasec/trivy:latest`, Prometheus textfile) has run within 7 days.
- [ ] Immich mobile clients: update phone apps to the current v3-compatible
  release **before** the server bump — the server only matches its own major
  ([Immich upgrading docs](https://docs.immich.app/install/upgrading)).
- [ ] If Immich OIDC (Keycloak) is enabled in Immich's system settings, note
  the issuer URL — v3 rejects invalid `oauth.issuerUrl` values (see
  photos-immich below).
- [ ] Decide Paperless duplicate policy: v3 accepts duplicates by default; set
  `PAPERLESS_CONSUMER_DELETE_DUPLICATES=true` in the same commit to keep
  current behavior (see documents-paperless below).
- [ ] Announce the window; uploads to photos/documents will fail or queue while
  stacks are down.

## iam-keycloak

In-place restart (minor upgrade 26.6.2 → 26.7.3 inside major 26; Keycloak 27
does not exist yet — `keycloak.org/docs/latest` release notes still stop at
26.7.0 as of 2026-09-16).

**Breaking changes** ([Keycloak 26.7.0 upgrading guide](https://www.keycloak.org/docs/26.7.0/upgrading/),
[26.7.0 release announcement](https://www.keycloak.org/2026/07/keycloak-2670-released)
— ships CVE fixes CVE-2026-9796, CVE-2026-9689, CVE-2026-9798, CVE-2026-11986):

- `view-system` admin role removed (26.5.4-era role); server-info access now
  requires `manage-realm` in `master`.
- Identity Provider alias immutable after creation via Admin REST API (400 on
  change).
- X509 client authentication requires a CA Subject DN option (not used in this
  deployment — no X509 authenticator configured).
- Organization member list endpoints return brief user representation by
  default (`?briefRepresentation=false` for full).
- Experimental `dynamic-scopes` feature renamed `parameterized-scopes` (not
  enabled here).
- PostgreSQL: async commit for ephemeral-table transactions (opt out with
  `--spi-connections-jpa--quarkus--async-commit=false`); new socket/query
  timeouts on DB connections.
- Self-registration with Verify Email: password field moves after email
  verification. Only relevant if self-registration is on in `company-realm` —
  check the realm before the window.

None of these touch the realm's OIDC client contracts, so oauth2-proxy,
Grafana, ocis, forgejo, and ferro configs need no changes.

**Edits (one commit):**

1. `stacks/iam/versions.env` — `KEYCLOAK_VERSION=26.6.2` → `26.7.3` (Renovate
   comment above it stays).
2. `stacks/iam/docker-compose.yml` — keycloak service image
   `ghcr.io/wyattau/evergreenimageregistry/keycloak:26.6.2` → `:26.7.3`.
3. `stacks/iam/docker-compose.yml` — postgres-iam (`.../postgres:17.10`) is
   NOT touched.

**Upgrade:** commit, push, `./scripts/deploy.sh`. Keycloak runs its automatic
relational DB migration at startup (Liquibase) — first boot is slower than
usual; the compose healthcheck already allows `start_period: 120s`.

**Validation:**

- `deploy.sh` Phase 4 polls `iam-keycloak` healthy (EIR shim TCP check on
  8080).
- The monitoring stack's own probes go green
  (`stacks/monitoring/victoriametrics/scrape.yml`): blackbox target
  `http://iam-keycloak:9000/health/ready` (management port, `KC_HEALTH_ENABLED=true`)
  and `http://iam-keycloak:8080/realms/company-realm`; the `keycloak` metrics
  job scrapes `iam-keycloak:9000`.
- SSO smoke tests, in this order: log into a `keycloak-auth@file`-gated app
  (homepage), then Grafana OIDC, then forgejo login, then a document open in
  ocis.

**Rollback:** revert the commit, push, `./scripts/deploy.sh` (deploy.sh also
auto-rolls-back on deploy failure). Because startup migrated the DB schema, an
image-only rollback after a successful migration is not supported upstream — if
login is broken after rollback, restore the database: per-stacked snapshot
`docker exec backup-restic restic restore --tag iam latest --target /tmp/restore`
(pattern from `stacks/backup/scripts/run-restore-test.sh`) or the
`keycloak.sql` dump, then restore
`/mnt/pool_HDD_x2/tank/datasources/sis/appdata/iam/postgres` per the restore
procedure in `docs/infrastructure.md` ("Restore from Backup") and redeploy the
old commit.

## storage-collabora

In-place restart for the annual major 25.04 → 26.04. `versions.env` already
tracks the target (`COLLABORA_VERSION=26.04.1.4.1`); only compose lags.

**Behavior changes** ([CODE 26.04 release notes](https://www.collaboraonline.com/code-26-04-release-notes/),
[upstream proxy docs](https://sdk.collaboraonline.com/docs/installation/Proxy_settings.html),
[upstream issue on 26.04 Docker regressions](https://github.com/CollaboraOnline/online/issues/15918)):

- New compact WebSocket URL. If the proxy does not match it, coolwsd falls back
  to the legacy URL and logs a server-audit warning — Traefik keeps working but
  check the audit log after upgrade; update Traefik rules only if warnings
  persist.
- Upstream hardened the image during the 26.04 cycle (26.04.2.x+): shell
  utilities removed, which broke `extra_params=` env parsing and `bash`-based
  healthchecks for some users (see linked issue). This compose sets
  `extra_params=` as an env var and uses a `bash /dev/tcp` healthcheck. The EIR
  build is pinned to 26.04.1.4.1 (pre-hardening), but verify after build; if
  the EIR Dockerfile tracks upstream, move `extra_params` to direct `command:`
  args and replace the healthcheck before merging.

**Edits (one commit):**

1. `stacks/storage/docker-compose.yml` — collabora service image
   `ghcr.io/wyattau/evergreenimageregistry/collabora-online:25.04.9.4.1` →
   `:26.04.1.4.1`.
2. `stacks/storage/versions.env` — no value change needed (already
   `26.04.1.4.1`); leave the file untouched.
3. Collabora mounts **no volumes** — documents live in ocis
   (`${DATA_BASE_PATH}/storage/ocis-data`), so nothing else to protect beyond
   the standard backup.

**Upgrade:** commit, push, `./scripts/deploy.sh`.

**Validation:**

- `storage-collabora` healthy (compose healthcheck: TCP 127.0.0.1:9980).
- Open a document from ocis (`cloud.<domain>`), edit, save; confirm the WOPI
  round-trip (`storage-collaboration` service talks to `storage-collabora:9980`).
- `collabora.<domain>` loads; no legacy-URL fallback audit warnings in coolwsd
  logs (`docker logs storage-collabora`).

**Rollback:** revert the commit, `./scripts/deploy.sh`. Stateless container —
no volume restore involved. This is the lowest-risk bump of the window; it runs
second so its validation doubles as an ocis/keycloak integration check.

## documents-paperless

Migration required. One-way Django DB migrations, search index replacement, and
task-history drop. Upstream gate: "Upgrading to Paperless-ngx v3 can only be
performed from version 2.20.15" — this stack is exactly on 2.20.15, so the
precondition is met ([v3 migration guide](https://docs.paperless-ngx.com/migration-v3/),
[v3.1.3 release](https://github.com/paperless-ngx/paperless-ngx/releases/tag/v3.1.3)).

Target **3.1.3** deliberately, not 3.0.x: v3.0.1 shipped a broken migration
(upstream instructs going to 3.0.2+), and 3.1.2 fixed
GHSA-2jhj-xqrq-rmrq — 3.1.3 contains that security fix.

**Breaking changes relevant here** (migration guide, [changelog](https://docs.paperless-ngx.com/changelog/)):

- `PAPERLESS_DBENGINE` is now **required** for PostgreSQL — this compose does
  not set it yet. Add it.
- `PAPERLESS_SECRET_KEY` now required — already set in this compose. No action.
- Document/thumbnail encryption removed (deprecated since paperless-ng 0.9.3).
  If encryption was ever enabled, run `decrypt_documents` **before** upgrading.
  This compose sets no passphrase — confirm in the admin UI that no encrypted
  documents exist before the window.
- Full-text search moves Whoosh → Tantivy. The index is rebuilt automatically
  on first startup (this is the long step); saved-view filters using explicit
  `note:`/`custom_field:` prefixes are migrated by data migration, plain-term
  views are not.
- Task tracking redesigned: all existing task history records are dropped.
- `PAPERLESS_OCR_MODE=force` (set in this compose) remains valid — only
  `skip`/`skip_noarchive` were removed in favor of the new
  `PAPERLESS_ARCHIVE_FILE_GENERATION` axis. `PAPERLESS_OCR_SKIP_ARCHIVE_FILE`
  is not set here. Review OCR settings in the admin UI after upgrade (DB values
  are auto-migrated).
- `CONSUMER_BARCODE_SCANNER` removed (pyzbar dropped, zxing-cpp only) — not set
  here. No action.
- Pre/post-consume scripts no longer receive positional arguments — none
  configured here. No action.
- API v1 removed; API versions below 9 dropped — any scripts/clients talking to
  the API must be current.
- Behind a reverse proxy, allauth login rate-limiting may 403 clients. If login
  fails after upgrade, set `PAPERLESS_TRUSTED_PROXIES` and/or
  `PAPERLESS_ALLAUTH_TRUSTED_CLIENT_IP_HEADER` (Traefik forwards
  `X-Forwarded-For`).
- Duplicates: v3 accepts duplicate documents by default. To preserve today's
  behavior add `PAPERLESS_CONSUMER_DELETE_DUPLICATES=true` (decide in
  pre-flight).

**Edits (one commit):**

1. `stacks/documents/versions.env` — `PAPERLESS_VERSION=2.20.15` → `3.1.3`.
2. `stacks/documents/docker-compose.yml` — paperless-webserver image
   `ghcr.io/wyattau/evergreenimageregistry/paperless-ngx:2.20.15` → `:3.1.3`.
3. `stacks/documents/docker-compose.yml` — add to paperless-webserver
   `environment:`:

   ```yaml
   - PAPERLESS_DBENGINE=postgresql
   ```

4. Optional, if keeping duplicate rejection: add
   `- PAPERLESS_CONSUMER_DELETE_DUPLICATES=true` next to it.
5. postgres 16.13 / redis 7.4 sidecars untouched.

**Upgrade:** commit, push, `./scripts/deploy.sh`. First boot runs migrations +
the Tantivy index rebuild; the compose healthcheck (`curl 127.0.0.1:8000`,
`start_period: 600s`, 5 retries) is sized for it, and deploy.sh allows 15 min
per container.

**Validation:**

- `documents-webserver` healthy; `documents-postgres` and `documents-redis`
  healthy.
- Log in through the `keycloak-auth@file` forwardAuth (validated right after
  the Keycloak step) — if 403, apply the trusted-proxy env vars above.
- Search returns hits (proves the Tantivy rebuild). This compose mounts no
  consume directory, so prove the consumer by reprocessing an existing
  document from the UI instead.
- Admin UI: OCR settings show the migrated values; task list is empty
  (expected — history was dropped).

**Rollback:** not a tag flip — the DB schema moved. Revert the commit, restore
data, then redeploy the old commit:

```bash
docker exec backup-restic restic restore --tag documents latest --target /tmp/restore
# then per docs/infrastructure.md "Restore from Backup":
#   stop the stack, copy /tmp/restore/data/documents/ back over
#   /mnt/pool_HDD_x2/tank/datasources/sis/appdata/documents/
#   (postgres, data, media, export), and redeploy the reverted commit.
```

The `paperless.sql` dump from the pre-flight backup is the cleanest DB source
(`docker exec documents-postgres pg_dumpall -U paperless` output, saved by
`stacks/backup/scripts/backup.sh`).

## photos-immich

Migration required. Server runs one-way DB migrations at startup; upstream
does not support downgrades, even within a minor
([Immich upgrading docs](https://docs.immich.app/install/upgrading),
[v3 migration guide](https://immich.app/blog/v3-migration),
[v3.0.0 release](https://immich.app/blog/v3.0.0-release)). Immich is the only
unblocked bump: compose uses upstream images, and the VectorChord DB migration
that v3 assumes is already in place (image
`ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`).

Target the newest stable v3.x tag at execution time (v3.0.0 released
2026-07-01; check GitHub releases during pre-flight). Pin both server and ML to
the same tag.

**Breaking changes relevant here** (v3 migration guide):

- pgvecto.rs support removed — already satisfied (VectorChord in use since the
  1.133-era migration; no `DB_VECTOR_EXTENSION` set).
- Removed env vars: `IMMICH_MACHINE_LEARNING_PING_TIMEOUT`,
  `MACHINE_LEARNING_PRELOAD__CLIP`, `MACHINE_LEARNING_PRELOAD__FACIAL_RECOGNITION`
  — none set in this compose. No action.
- ML requires x86-64-v2 CPUs (numpy 2.4) — virtually every mainstream x86-64
  CPU since ~2010 qualifies; no action expected for the TrueNAS host.
- OAuth: insecure (http) issuer requests disallowed by default;
  `oauth.issuerUrl` must parse as a URL. Applies only if Immich's own OIDC
  against Keycloak is enabled in Immich system settings (photos route is public
  in Traefik; check Admin > Settings before the window).
- Exported metric names change: underscores become dots. `IMMICH_METRICS=true`
  is set — update any dashboards/alert rules in `stacks/monitoring/` that query
  immich metrics by old names.
- API breaking changes (Zod validation, removed endpoints, integer types) —
  affect third-party API consumers only; the compose healthcheck endpoint
  `GET /api/server/ping` is unaffected.
- Mobile apps must be on a v3-compatible release **before** the server bump
  (pre-flight item).

**Edits (one commit):**

1. `stacks/photos/versions.env` — `IMMICH_VERSION=v2.7.5` → `v3.x` and
   `IMMICH_ML_VERSION=v2.7.5` → same tag (lines under the Renovate comments).
2. `stacks/photos/docker-compose.yml` — immich-server image
   `ghcr.io/immich-app/immich:v2.7.5` → `:v3.x`; immich-ml image
   `ghcr.io/immich-app/immich-machine-learning:v2.7.5` → `:v3.x`.
3. `stacks/photos/docker-compose.yml` — immich-postgres image stays
   `14-vectorchord0.4.3-pgvectors0.2.0`; EIR valkey `9.0.4` stays.
4. `versions.digests` — refresh `IMMICH_DIGEST`, `IMMICH_ML_DIGEST`,
   `IMMICH_POSTGRES_DIGEST` for the new tags (upstream images are
   digest-checked by `scripts/verify-digests.sh`; follow the `86263e3`
   pattern of updating digests in the bump commit).

**Upgrade:** commit, push, `./scripts/deploy.sh`. First server boot runs DB
migrations; logs may sit at `Reindexing clip_index` / `Reindexing face_index`
for minutes on large libraries — that is normal, give it time.

**Validation:**

- `photos-server`, `photos-postgres`, `photos-valkey` healthy (compose
  healthchecks; server pings `http://127.0.0.1:2283/api/server/ping`).
- Upload a test asset from a phone (also proves mobile/server compatibility);
  browse the library; confirm an ML job (smart search or face job) completes.
- Metrics scrape still parsed in Grafana/VictoriaMetrics after the name change.

**Rollback:** no in-place downgrade exists. Restore volumes, then redeploy the
old commit:

```bash
docker exec backup-restic restic restore --tag photos latest --target /tmp/restore
# per docs/infrastructure.md "Restore from Backup": stop the stack, restore
# /mnt/pool_HDD_x2/tank/datasources/sis/appdata/photos/{db,upload} (and
# model-cache if desired) from the restore, then redeploy the reverted commit.
```

The `immich.sql` dump from the pre-flight backup is the authoritative DB copy.

## Completed bumps (single source of truth)

These are done and deployed; nothing to execute. Listed with digest-pin state
(`versions.digests`, generated 2026-05-28, refreshed commit-by-commit;
`scripts/verify-digests.sh` enforces it for upstream images — EIR images
`ghcr.io/wyattau/*` are skipped by design and never digest-pinned).

| Stack | Component | Deployed version | Image | Digest pin |
| --- | --- | --- | --- | --- |
| collaboration | Synapse | v1.161.0 (commit `86263e3`, 2026-09-15) | `matrixdotorg/synapse:v1.161.0` | `SYNAPSE_DIGEST` — refreshed in bump commit |
| collaboration | Element Web | v1.12.27 (commit `86263e3`) | `vectorim/element-web:v1.12.27` | `ELEMENT_DIGEST` — refreshed in bump commit |
| rss | FreshRSS | 1.30.0 | `freshrss/freshrss:1.30.0` | `FRESHRSS_DIGEST` |
| security | CrowdSec | compose runs 1.7.8; versions.env says v1.8.1 | `ghcr.io/wyattau/evergreenimageregistry/crowdsec:1.7.8` | `CROWDSEC_DIGEST` (stale vs versions.env — see drift table) |
| tunnel | cloudflared | versions.env 2026.9.1; compose runs EIR `:latest` | `ghcr.io/wyattau/evergreenimageregistry/cloudflared:latest` | none — EIR, exempt from pinning |
| vpn | WireGuard | 1.0.20260223 | `linuxserver/wireguard:1.0.20260223` | `WIREGUARD_DIGEST` |

Accepted-risk context (upstream is ahead, EIR image missing — verified in the
registry 2026-09-28; not scheduled in this window):

| Stack | Component | Deployed | Upstream | Blocker |
| --- | --- | --- | --- | --- |
| vaultwarden | Vaultwarden | 1.36.0 | 1.37.x | EIR has only `1.36.0`; `VAULTWARDEN_DIGEST` pins the running image |
| operations | Forgejo | 15.0.4 (compose) | v15.0.8 | EIR has only `15.0.4`/`v15.0.4`; no digest pin (EIR) |

## versions.env vs compose drift (known, unresolved)

These mismatches exist on `main` today. They are recorded here so the runbook
matches reality; reconcile them in ordinary Renovate windows, not during this
one (except where noted).

| Stack | versions.env | compose | Note |
| --- | --- | --- | --- |
| storage | COLLABORA 26.04.1.4.1 | 25.04.9.4.1 | This is the pending storage bump (runbook above) |
| security | CROWDSEC v1.8.1 | 1.7.8 | compose behind env; verify EIR 1.8.1 build before reconciling |
| backup | RESTIC 0.19.1 | 0.18.1 | compose behind env |
| operations | FORGEJO 15.0.2 | 15.0.4 | env behind compose |
| storage | OCIS 8.0.3 | 8.0.4 | env behind compose |
| proxy | TRAEFIK v3.7.1 | 3.7.3 | env behind compose |
| proxy | OAUTH2_PROXY v7.15.2 | 7.15.3 | env behind compose |
| monitoring | GRAFANA 12.2.8-security-04 | 12.2.9 | env behind compose |
| monitoring | CADVISOR v0.55.1 | v0.52.1 | compose behind env |
| monitoring | NODE_EXPORTER v1.11.1 | v1.9.1 | compose behind env |
| monitoring | POSTGRES_EXPORTER v0.19.1 | v0.17.1 | compose behind env |

The four stacks in this runbook (iam, documents, photos) currently have
versions.env and compose in agreement; storage/collabora is the only one where
the bump is already half-staged in versions.env.

## Data volumes and backup coverage

Production data root: `DATA_BASE_PATH` =
`/mnt/pool_HDD_x2/tank/datasources/sis/appdata` (deploy.sh, backup.sh; the
`global.env.example` placeholder differs). Restic repo:
`/mnt/pool_HDD_x2/tank/datasources/sis/backups/restic-repo-new`, offsite to
Backblaze B2.

Volumes for the stacks in this window (from the compose files):

| Stack | Compose volumes |
| --- | --- |
| iam | `${DATA_BASE_PATH}/iam/postgres` (keycloak DB); `${DATA_BASE_PATH}/iam/realm-export` written by `run-keycloak-export.sh` |
| storage | collabora: **none** (stateless). ocis: `${DATA_BASE_PATH}/storage/ocis-config`, `${DATA_BASE_PATH}/storage/ocis-data` |
| documents | `${DATA_BASE_PATH}/documents/postgres`, `/documents/redis`, `/documents/data` (config), `/documents/media`, `/documents/export` |
| photos | `${DATA_BASE_PATH}/photos/upload`, `/photos/db` (immich-postgres), `/photos/model-cache` (ML) |

Backup coverage per stack (from `stacks/backup/scripts/backup.sh` — per-stack
restic tags + DB dumps; and `stacks/backup/scripts/run-backup.sh` —
`pg_dump -Fc` per DB):

| Stack | Restic appdata tag | DB dump | Covered for this window |
| --- | --- | --- | --- |
| photos | yes (`photos`) | `immich.sql` via `photos-postgres` | yes |
| documents | yes (`documents`) | `paperless.sql` via `documents-postgres` | yes |
| iam | yes (`iam`) | `keycloak.sql` via `iam-postgres` + realm-export JSON | yes |
| storage | yes (`storage`) | n/a (no DB) | yes |
| vaultwarden | yes | `vaultwarden.sqlite3` copy | yes |
| collaboration, rss, books, utility, vpn, security, proxy, monitoring, operations | yes (per-stack tags) | forgejo/synapse dumps | yes |
| project-management | **no appdata tag, no DB dump** | — | gap (not in this window) |
| accounting | **no appdata tag, no DB dump** | — | gap (not in this window) |
| erpnext | no appdata tag | `erpnext.sql` dumped | partial |
| headscale | no appdata tag | `headscale.sql` dumped | partial |
| ferro | no appdata tag, no DB dump (has a postgres sidecar) | — | gap (not in this window) |

SOPS secret files: every stack has `secrets/<stack>.env.encrypted` — verified
2026-09-28: accounting, backup, books, collaboration, documents, erpnext,
ferro, iam, monitoring, operations, photos, project-management, proxy, rss,
security, storage, tunnel, updater, utility, vaultwarden, vpn, webhook (22
files; `backup.env.encrypted` holds the restic/B2 credentials for the backup
stack itself). `terraform.env.encrypted` was removed on 2026-09-28.

## Post-window tasks

- [ ] Re-run `./scripts/verify-digests.sh` (new upstream digests must pass).
- [ ] Trigger the Vulnerability Scan workflow manually and compare finding
      counts per stack against the pre-window baseline (bumps should not
      increase HIGH/CRITICAL counts; the paperless 3.1.3 and keycloak 26.7.3
      bumps exist partly to clear known CVEs).
- [ ] Watch `sis_backup_last_success` / `BackupStale` / `BackupOffsiteSyncStale`
      for the nightly after the window.
- [ ] Confirm the monthly restore test passes on the 1st with the new volumes'
      data.
- [ ] File follow-ups: backup gaps for project-management, accounting, ferro
      (and appdata tags for erpnext/headscale); drift-table reconciliation;
      EIR builds for vaultwarden 1.37.x and forgejo v15.0.8 to clear the
      accepted-risk entries.
- [ ] Update the table at the top of this file as each stack completes — the
      runbook stays the single source of truth.
