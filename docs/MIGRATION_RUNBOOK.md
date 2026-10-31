# SimpleInfrastructureStack: Major-Version Migration Runbook
> maintenance window. No version values have been bumped; this document is the
upstream (non-EIR) images; see the synapse bump commit `86263e3` for the
| 4 | photos | Immich | v2.7.5 | latest v3.x | Migration required (one-way DB migration at startup) | None; upstream images |
1. **iam-keycloak; 30–45 min.** Nothing may authenticate against Keycloak
2. **storage-collabora; 30–45 min.** Validated by opening a document through
   ocis, so it follows Keycloak. Stateless (no volumes); cheapest rollback in
3. **documents-paperless; 60–120 min.** Login is gated by
4. **photos-immich; 60–120 min.** Independent of Keycloak (public route). The
  (`stacks/backup/scripts/run-backup.sh`; `pg_dump -Fc` per DB + full `/data`
  (`stacks/backup/scripts/run-keycloak-export.sh`; same invocation its cron
  release **before** the server bump; the server only matches its own major
  the issuer URL; v3 rejects invalid `oauth.issuerUrl` values (see
does not exist yet; `keycloak.org/docs/latest` release notes still stop at
- ships CVE fixes CVE-2026-9796, CVE-2026-9689, CVE-2026-9798, CVE-2026-11986):
  deployment; no X509 authenticator configured).
  verification. Only relevant if self-registration is on in `company-realm` -
1. `stacks/iam/versions.env`; `KEYCLOAK_VERSION=26.6.2` → `26.7.3` (Renovate
2. `stacks/iam/docker-compose.yml`; keycloak service image
3. `stacks/iam/docker-compose.yml`; postgres-iam (`.../postgres:17.10`) is
relational DB migration at startup (Liquibase); first boot is slower than
image-only rollback after a successful migration is not supported upstream; if
  to the legacy URL and logs a server-audit warning; Traefik keeps working but
1. `stacks/storage/docker-compose.yml`; collabora service image
2. `stacks/storage/versions.env`; no value change needed (already
3. Collabora mounts **no volumes**; documents live in ocis
**Rollback:** revert the commit, `./scripts/deploy.sh`. Stateless container -
performed from version 2.20.15"; this stack is exactly on 2.20.15, so the
GHSA-2jhj-xqrq-rmrq; 3.1.3 contains that security fix.
- `PAPERLESS_DBENGINE` is now **required** for PostgreSQL; this compose does
- `PAPERLESS_SECRET_KEY` now required; already set in this compose. No action.
  This compose sets no passphrase; confirm in the admin UI that no encrypted
- `PAPERLESS_OCR_MODE=force` (set in this compose) remains valid; only
- `CONSUMER_BARCODE_SCANNER` removed (pyzbar dropped, zxing-cpp only); not set
- Pre/post-consume scripts no longer receive positional arguments; none
- API v1 removed; API versions below 9 dropped; any scripts/clients talking to
1. `stacks/documents/versions.env`; `PAPERLESS_VERSION=2.20.15` → `3.1.3`.
2. `stacks/documents/docker-compose.yml`; paperless-webserver image
3. `stacks/documents/docker-compose.yml`; add to paperless-webserver
  the Keycloak step); if 403, apply the trusted-proxy env vars above.
  (expected; history was dropped).
**Rollback:** not a tag flip; the DB schema moved. Revert the commit, restore
- pgvecto.rs support removed; already satisfied (VectorChord in use since the
 ; none set in this compose. No action.
- ML requires x86-64-v2 CPUs (numpy 2.4); virtually every mainstream x86-64
  is set; update any dashboards/alert rules in `stacks/monitoring/` that query
- API breaking changes (Zod validation, removed endpoints, integer types) -
1. `stacks/photos/versions.env`; `IMMICH_VERSION=v2.7.5` → `v3.x` and
2. `stacks/photos/docker-compose.yml`; immich-server image
3. `stacks/photos/docker-compose.yml`; immich-postgres image stays
4. `versions.digests`; refresh `IMMICH_DIGEST`, `IMMICH_ML_DIGEST`,
for minutes on large libraries; that is normal, give it time.
`scripts/verify-digests.sh` enforces it for upstream images; EIR images
| collaboration | Synapse | v1.161.0 (commit `86263e3`, 2026-09-15) | `matrixdotorg/synapse:v1.161.0` | `SYNAPSE_DIGEST`; refreshed in bump commit |
| collaboration | Element Web | v1.12.27 (commit `86263e3`) | `vectorim/element-web:v1.12.27` | `ELEMENT_DIGEST`; refreshed in bump commit |
| security | CrowdSec | compose runs 1.7.8; versions.env says v1.8.1 | `ghcr.io/wyattau/evergreenimageregistry/crowdsec:1.7.8` | `CROWDSEC_DIGEST` (stale vs versions.env; see drift table) |
| tunnel | cloudflared | versions.env 2026.9.1; compose runs EIR `:latest` | `ghcr.io/wyattau/evergreenimageregistry/cloudflared:latest` | none; EIR, exempt from pinning |
Accepted-risk context (upstream is ahead, EIR image missing; verified in the
Backup coverage per stack (from `stacks/backup/scripts/backup.sh`; per-stack
restic tags + DB dumps; and `stacks/backup/scripts/run-backup.sh` -
| project-management | **no appdata tag, no DB dump** |; | gap (not in this window) |
| accounting | **no appdata tag, no DB dump** |; | gap (not in this window) |
| ferro | no appdata tag, no DB dump (has a postgres sidecar) |; | gap (not in this window) |
SOPS secret files: every stack has `secrets/<stack>.env.encrypted`; verified
- [ ] Update the table at the top of this file as each stack completes; the