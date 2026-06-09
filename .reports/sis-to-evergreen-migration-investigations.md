# EIR Migration: Items Requiring Investigation

**Date:** 2026-06-09
**Parent Report:** `.reports/sis-to-evergreen-migration-report.md`

---

## 1. Stubs and Placeholders

### `erpnext` — STUB (Not a Real Image)

| Field | Value |
|-------|-------|
| EIR Directory | `images/erpnext/` |
| Manifest Version | `16.0.0` (but Dockerfile label says `15.11.0` — **version mismatch**) |
| Status | **STUB** — empty wolfi-base skeleton, no application binaries or code |

**Details:**
- Dockerfile creates wolfi-base container with `ca-certificates` and `curl`
- Creates empty directories: `/app`, `/var/log/erpnext`, `/var/cache/erpnext`
- Sets entrypoint to `/usr/local/bin/shim run` but **no ERPNext binaries are ever installed**
- `manifest.toml` has no `source.url`, `source.vendor`, `source.license`, or `upstream_version` fields
- This is a skeleton that was never completed

**Impact:** Cannot use EIR `erpnext` image. Must continue using `frappe/erpnext:v16.0.0` upstream.

**Action:** Keep upstream `frappe/erpnext`. Either complete the EIR stub or skip.

---

## 2. Version Mismatches

### `postgresql-exporter` — EIR 4 Versions Behind

| Field | SIS | EIR |
|-------|-----|-----|
| Version | `v0.19.1` | `0.15.0` |
| Delta | — | 4 versions behind |

**Impact:** May miss newer exporters, query compatibility, or bug fixes. Needs testing.

**Action:** Verify if `0.15.0` works with PostgreSQL 17.10. Check changelog for breaking changes between 0.15.0 and 0.19.1.

### `redis` — EIR Slightly Behind

| Field | SIS | EIR |
|-------|-----|-----|
| Version | `7.4.9-alpine` | `7.4.1` |
| Delta | — | 8 patch releases behind |

**Impact:** Minor. Likely no functional difference for SIS use case (documents stack).

**Action:** Accept EIR version or pin to SIS version upstream.

### `immich` — EIR Ancient (v1 vs v2)

| Field | SIS | EIR |
|-------|-----|-----|
| Version | `v2.7.5` | `1.106.0` |
| Delta | — | Entire major version behind |

**Impact:** Immich v2 has breaking schema changes from v1. Cannot migrate databases across major versions.

**Action:** Keep upstream `ghcr.io/immich-app/immich:v2.7.5`. EIR `immich` is not viable.

---

## 3. Uncontrolled Versions (`:latest` Pins)

### `synapse` — No Version Pin

| Field | Value |
|-------|-------|
| EIR Version | `latest` |
| SIS Version | `v1.152.1` |
| Status | Real image (repack of upstream), but unpinned |

**Details:** EIR Dockerfile uses `ARG VERSION=latest` and pulls from `matrixdotorg/synapse:latest`. No specific version is pinned, so builds are non-reproducible.

**Action:** Pin EIR `synapse` to `v1.152.1` (matching SIS) before migration.

### `taiga-back` — No Version Pin

| Field | Value |
|-------|-------|
| EIR Version | `latest` |
| SIS Version | `6.9.0` |
| Status | Real image (repack), but unpinned |

**Action:** Pin EIR `taiga-back` to `6.9.0` (matching SIS) before migration.

### `taiga-front` — Version Mismatch

| Field | Value |
|-------|-------|
| EIR Version | `6.9.0` |
| SIS Version | `6.9.0` |
| Status | Version matches. |

**Note:** `taiga-front` is properly versioned (no `:latest`).

### `taiga-events` — No Version Pin

| Field | Value |
|-------|-------|
| EIR Version | `latest` |
| SIS Version | `6.9.0` |
| Status | Real image (repack), but unpinned |

**Action:** Pin EIR `taiga-events` to `6.9.0` (matching SIS) before migration.

### `taiga-protected` — Version Mismatch?

| Field | Value |
|-------|-------|
| EIR Version | `6.9.0` |
| SIS Version | `6.9.0` |
| Status | Version matches. |

**Note:** `taiga-protected` appears properly versioned.

---

## 4. Duplicate Images

### `blackbox-exporter` vs `prometheus-blackbox-exporter` — Same Tool Built Twice

| Directory | Version | Source |
|-----------|---------|--------|
| `blackbox-exporter/` | `v0.28.0` | Builds `blackbox_exporter` from `prometheus/blackbox_exporter` Go source |
| `prometheus-blackbox-exporter/` | `0.28.0` | Builds `blackbox_exporter` from the **same** GitHub repo |

**Details:** Functionally identical — both compile the same upstream tool. The only differences are labels and that `prometheus-blackbox-exporter/` also copies a `blackbox.yml` config file.

**Action:** Use `blackbox-exporter` (matches SIS naming convention `prom/blackbox-exporter`). Remove or deprecate `prometheus-blackbox-exporter` duplicate.

---

## 5. Custom Images With No EIR Equivalent

### `ghcr.io/immich-app/postgres` — Custom Postgres with pgvector

| Field | Value |
|-------|-------|
| SIS Version | `14-vectorchord0.4.3-pgvectors0.2.0` |
| EIR Has It | No — EIR has generic `postgres`/`postgresql-*` but none include vectorchord/pgvector extensions |
| Status | Immich requires pgvector for vector search on photos |

**Action:** Keep upstream custom Postgres image. EIR generic postgres cannot replace it.

### `infra-webhook:latest` — Locally Built

| Field | Value |
|-------|-------|
| SIS Source | `stacks/webhook/Dockerfile` (alpine-based, ~50 lines) |
| EIR Has It | No — no webhook relay image in EIR |
| Status | Simple Go/Python webhook relay, locally built |

**Action:** Keep locally built image. Alternatively, consider contributing a webhook image to EIR.

---

## 6. SIS Custom `ghcr.io/wyattau/*` Images — Deduplication Decision

SIS uses several custom-built images from your own GHCR. EIR has matching hardened images. Decision needed on whether to:

| SIS Custom Image | EIR Equivalent | Question |
|------------------|----------------|-----------|
| `ghcr.io/wyattau/forgejo:15.0.2` | `forgejo:15.0.2` | Keep custom or switch to EIR? |
| `ghcr.io/wyattau/traefik:v3.7.1` | `traefik:v3.7.1` | Keep custom or switch to EIR? |
| `ghcr.io/wyattau/cloudflared:2026.5.0` | `cloudflared:2026.5.0` | Keep custom or switch to EIR? |
| `ghcr.io/wyattau/matrix-hookshot:7.3.3` | `matrix-hookshot` | Keep custom or switch to EIR? |

**Action:** Compare SIS custom Dockerfiles with EIR Dockerfiles. If EIR versions are functionally equivalent, switch to EIR and stop building custom images.

---

## Summary

| Category | Count | Items |
|----------|-------|-------|
| Stubs/Placeholders | 1 | `erpnext` |
| Version Behind (>2 minor) | 2 | `postgresql-exporter` (4 versions), `immich` (major version) |
| Version Behind (<1 minor) | 1 | `redis` (8 patches) |
| Uncontrolled (`:latest`) | 3 | `synapse`, `taiga-back`, `taiga-events` |
| Duplicates | 1 | `prometheus-blackbox-exporter` (same as `blackbox-exporter`) |
| No EIR Equivalent | 2 | Immich custom Postgres, locally-built webhook |
| Custom Image Dedup | 4 | forgejo, traefik, cloudflared, matrix-hookshot |
| **Total items** | **14** | — |
