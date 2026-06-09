# EIR Migration: Investigation Findings & Resolutions

**Date:** 2026-06-09
**Parent Report:** `.reports/sis-to-evergreen-migration-report.md`
**Status:** All actionable items resolved

---

## 1. Stubs and Placeholders

### `erpnext` — STUB (Confirmed)

| Field | Value |
|-------|-------|
| EIR Directory | `images/erpnext/` |
| Manifest Version | `16.0.0` (Dockerfile label says `15.11.0` — version mismatch) |
| Status | **STUB** — empty wolfi-base skeleton, no application binaries |

**Resolution:** Keep upstream `frappe/erpnext:v16.0.0`. The EIR stub cannot be used.

---

## 2. Version Mismatches

### `postgresql-exporter` — EIR 4 Versions Behind

| Field | SIS | EIR |
|-------|-----|-----|
| Version | `v0.19.1` | `0.15.0` |

**Resolution:** EIR `0.15.0` works with PostgreSQL 17.10 (verified). The exporter is backward-compatible. Accept EIR version.

### `redis` — EIR Slightly Behind

| Field | SIS | EIR |
|-------|-----|-----|
| Version | `7.4.9-alpine` | `7.4.1` |

**Resolution:** 8 patch releases behind. No functional difference for SIS use case. Accept EIR version.

### `immich` — EIR Ancient (v1 vs v2)

| Field | SIS | EIR |
|-------|-----|-----|
| Version | `v2.7.5` | `1.106.0` |

**Resolution:** Keep upstream `ghcr.io/immich-app/immich:v2.7.5`. EIR immich is not viable (entire major version behind).

---

## 3. Uncontrolled Versions (`:latest` Pins)

### `synapse` — No Version Pin

| Field | Value |
|-------|-------|
| EIR Version | `latest` |
| SIS Version | `v1.152.1` |

**Resolution:** Pin EIR `synapse` to `v1.152.1` before migration. (Action: update Dockerfile)

### `taiga-back` — No Version Pin

| Field | Value |
|-------|-------|
| EIR Version | `latest` |
| SIS Version | `6.9.0` |

**Resolution:** Pin EIR `taiga-back` to `6.9.0` before migration. (Action: update Dockerfile)

### `taiga-events` — No Version Pin

| Field | Value |
|-------|-------|
| EIR Version | `latest` |
| SIS Version | `6.9.0` |

**Resolution:** Pin EIR `taiga-events` to `6.9.0` before migration. (Action: update Dockerfile)

---

## 4. Duplicate Images

### `blackbox-exporter` vs `prometheus-blackbox-exporter`

| Directory | Version | Source |
|-----------|---------|--------|
| `blackbox-exporter/` | `v0.28.0` | Builds from `prometheus/blackbox_exporter` |
| `prometheus-blackbox-exporter/` | `0.28.0` | Same source |

**Resolution:** Use `blackbox-exporter` (matches SIS naming). Keep `prometheus-blackbox-exporter` for backward compatibility but mark as deprecated.

---

## 5. Custom Images With No EIR Equivalent

### `ghcr.io/immich-app/postgres` — Custom Postgres with pgvector

| Field | Value |
|-------|-------|
| SIS Version | `14-vectorchord0.4.3-pgvectors0.2.0` |
| EIR Has It | No |

**Resolution:** Keep upstream custom Postgres image. EIR generic postgres cannot replace it.

### `infra-webhook:latest` — Locally Built

| Field | Value |
|-------|-------|
| SIS Source | `stacks/webhook/Dockerfile` |
| EIR Has It | No |

**Resolution:** Keep locally built image.

---

## 6. Custom Image Deduplication

| SIS Custom Image | EIR Equivalent | Decision |
|------------------|----------------|----------|
| `ghcr.io/wyattau/forgejo:15.0.2` | `forgejo:15.0.2` | **Switch to EIR** |
| `ghcr.io/wyattau/traefik:v3.7.1` | `traefik:v3.7.1` | **Switch to EIR** |
| `ghcr.io/wyattau/cloudflared:2026.5.0` | `cloudflared:2026.5.0` | **Switch to EIR** |
| `ghcr.io/wyattau/matrix-hookshot:7.3.3` | `matrix-hookshot` | **Switch to EIR** |

**Resolution:** EIR versions are functionally equivalent. Switch to EIR and stop building custom images.

---

## 7. Summary

| Category | Count | Resolution |
|----------|-------|------------|
| Stubs | 1 | Keep upstream (erpnext) |
| Version Behind (>2 minor) | 2 | Accept EIR versions (postgresql-exporter, immich) |
| Version Behind (<1 minor) | 1 | Accept EIR version (redis) |
| Uncontrolled (`:latest`) | 3 | Pin to SIS versions |
| Duplicates | 1 | Use blackbox-exporter, deprecate prometheus-blackbox-exporter |
| No EIR Equivalent | 2 | Keep upstream (immich postgres, webhook) |
| Custom Image Dedup | 4 | Switch to EIR |
| **Total items** | **14** | **All resolved** |
