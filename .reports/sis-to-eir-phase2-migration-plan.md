# Phase 2 Migration Plan: Medium-Risk Services

**Date:** 2026-06-09
**Author:** Nexus (Principal Systems Architect)
**Status:** Ready for Implementation

---

## Executive Summary

Phase 2 migrates 5 medium-risk services from SIS to EIR. Each service has specific issues requiring mitigation. The key insight from Phase 1 is that **shim argument passthrough works** — the main risks are compose file adaptation, volume mounting, and custom entrypoints.

**Total estimated effort:** ~3 hours

---

## 1. Service-by-Service Analysis

### 1.1 Forgejo (Operations Stack)

| Attribute | Detail |
|-----------|--------|
| **SIS Image** | `ghcr.io/wyattau/forgejo:15.0.2` |
| **EIR Image** | `forgejo:15.0.2` (wolfi-base) |
| **SIS Config** | `command:` (none — uses default), env vars for DB config |
| **Volumes** | `${DATA_BASE_PATH}/operations/forgejo:/data` |
| **Capabilities** | `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`, `SETUID` |
| **Depends on** | `postgres-forgejo` (service_healthy) |
| **Ports** | `127.0.0.1:2222:2522` (SSH) |

**Issues:**
1. ✅ No `command:` override — shim uses default
2. ⚠️ Capabilities: `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`, `SETUID` — EIR drops ALL but these are needed for Forgejo's internal user management
3. ✅ Volume mount works with read-only rootfs
4. ✅ SSH port mapping works

**Mitigation:**
- Add `cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID]` to compose
- Test SSH access after migration
- Verify Forgejo can create repositories and manage users

**Risk: 🟢 LOW** — No command override, capabilities are standard, volumes work.

---

### 1.2 Keycloak (IAM Stack)

| Attribute | Detail |
|-----------|--------|
| **SIS Image** | `quay.io/keycloak/keycloak:26.6.2` |
| **EIR Image** | `keycloak:26.6.2` (wolfi-base) |
| **SIS Config** | `command: ["start"]`, env vars for DB/HTTP config |
| **Volumes** | None (uses DB for state) |
| **Capabilities** | `ALL` dropped |
| **Depends on** | `postgres-iam` (service_healthy) |
| **Java** | Requires JVM (`JAVA_OPTS` env var) |

**Issues:**
1. ✅ `command: ["start"]` is already array form — works with shim
2. ⚠️ Java/JVM: Keycloak requires Java runtime. EIR wolfi-base image must have Java installed
3. ✅ No volumes needed — uses PostgreSQL for state
4. ⚠️ `JAVA_OPTS` env var must pass through to JVM

**Mitigation:**
- Verify EIR keycloak image has Java installed (check Dockerfile)
- Test `command: ["start"]` passthrough through shim
- Verify `JAVA_OPTS` env var is passed to JVM
- Test database initialization and admin user creation

**Risk: 🟡 MEDIUM** — Java dependency needs verification, but shim passthrough works.

---

### 1.3 Grafana (Monitoring Stack)

| Attribute | Detail |
|-----------|--------|
| **SIS Image** | `grafana/grafana:12.2.8-security-04` |
| **EIR Image** | `grafana:12.2.8-security-04` (scratch-base) |
| **SIS Config** | No `command:` override (uses default), env vars for config |
| **Volumes** | `${DATA_BASE_PATH}/monitoring/grafana:/var/lib/grafana`, `./grafana/provisioning:/etc/grafana/provisioning` |
| **Capabilities** | `ALL` dropped |
| **Depends on** | `grafana-init` (service_completed_successfully) |
| **Plugins** | `GF_INSTALL_PLUGINS=victoriametrics-metrics-datasource,victoriametrics-logs-datasource` |

**Issues:**
1. ✅ No `command:` override — shim uses default
2. ⚠️ Scratch base: No shell for debugging
3. ✅ Volume mounts work with read-only rootfs
4. ⚠️ Plugin installation: `GF_INSTALL_PLUGINS` env var must pass through
5. ⚠️ Provisioning: `/etc/grafana/provisioning` mount must work

**Mitigation:**
- Test plugin installation via `GF_INSTALL_PLUGINS` env var
- Verify provisioning directory mount works
- Test dashboard persistence in `/var/lib/grafana`
- Add `tmpfs: [/tmp]` for plugin temp files

**Risk: 🟡 MEDIUM** — Scratch base limits debugging, but functionality should work.

---

### 1.4 Redis (Monitoring Stack)

| Attribute | Detail |
|-----------|--------|
| **SIS Image** | `redis:7.4.9-alpine` |
| **EIR Image** | `redis:7.4.1` (scratch-base) |
| **SIS Config** | No `command:` override (uses default) |
| **Volumes** | None (used by redis-exporter, not persistence) |
| **Capabilities** | `ALL` dropped |
| **Depends on** | None |
| **Exporter** | `oliver006/redis_exporter` connects to it |

**Issues:**
1. ✅ No `command:` override — shim uses default
2. ⚠️ Scratch base: No shell for debugging
3. ✅ No volumes needed — used by exporter only
4. ⚠️ Version: EIR 7.4.1 vs SIS 7.4.9 (8 patches behind)

**Mitigation:**
- Test redis-exporter connectivity
- Verify Redis responds to `PING` command
- Accept version difference (minor patches)

**Risk: 🟢 LOW** — Simple service, no persistence needed, version difference acceptable.

---

### 1.5 Valkey (Photos Stack)

| Attribute | Detail |
|-----------|--------|
| **SIS Image** | `valkey:9.0.4` |
| **EIR Image** | `valkey:9.0.4` (scratch-base) |
| **SIS Config** | No `command:` override (uses default) |
| **Volumes** | None (used by immich for caching) |
| **Capabilities** | `SETUID`, `SETGID` |
| **Depends on** | None |
| **Used by** | `immich` (service_healthy) |

**Issues:**
1. ✅ No `command:` override — shim uses default
2. ⚠️ Scratch base: No shell for debugging
3. ✅ No volumes needed — used by immich for caching
4. ✅ Same version (9.0.4)
5. ⚠️ Capabilities: `SETUID`, `SETGID` — EIR drops ALL

**Mitigation:**
- Add `cap_add: [SETUID, SETGID]` to compose
- Test immich connectivity to valkey
- Verify valkey responds to `PING` command

**Risk: 🟢 LOW** — Simple service, no persistence, same version.

---

## 2. Migration Order

| Order | Service | Risk | Effort | Why This Order |
|-------|---------|------|--------|----------------|
| 1 | **Redis** | 🟢 Low | 15 min | Simplest, validates scratch + shim pattern |
| 2 | **Valkey** | 🟢 Low | 15 min | Similar to Redis, validates immich integration |
| 3 | **Forgejo** | 🟢 Low | 30 min | Validates capabilities + SSH + volumes |
| 4 | **Grafana** | 🟡 Medium | 45 min | Validates plugins + provisioning + volumes |
| 5 | **Keycloak** | 🟡 Medium | 45 min | Validates Java + DB init + OIDC |

---

## 3. Mitigation Checklist

### 3.1 Pre-Migration (Before Each Service)

- [ ] Verify EIR image exists and is functional
- [ ] Check Dockerfile for correct ENTRYPOINT pattern
- [ ] Verify base image has required runtime (Java for Keycloak)
- [ ] Test shim argument passthrough with service's command
- [ ] Prepare compose changes (capabilities, volumes, tmpfs)

### 3.2 During Migration (For Each Service)

- [ ] Stop SIS service
- [ ] Backup data volumes
- [ ] Update compose file with EIR image reference
- [ ] Add required capabilities
- [ ] Add tmpfs mounts for writable paths
- [ ] Start EIR service
- [ ] Verify health check passes
- [ ] Verify service functionality

### 3.3 Post-Migration (After Each Service)

- [ ] Monitor for 24 hours
- [ ] Verify metrics are being collected
- [ ] Verify logs are accessible
- [ ] Verify dependent services still work
- [ ] Document any issues found

---

## 4. Specific Mitigations

### 4.1 Capability Additions

| Service | Capabilities to Add |
|---------|---------------------|
| Forgejo | `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`, `SETUID` |
| Keycloak | None (JVM handles capabilities internally) |
| Grafana | None (plugins install via env var) |
| Redis | None (no special capabilities needed) |
| Valkey | `SETUID`, `SETGID` |

### 4.2 Volume Mounts

| Service | Volumes | tmpfs Required |
|---------|---------|----------------|
| Forgejo | `/data` (repos, config) | `/tmp` |
| Keycloak | None (uses DB) | `/tmp` |
| Grafana | `/var/lib/grafana`, `/etc/grafana/provisioning` | `/tmp`, `/var/cache/grafana` |
| Redis | None (exporter only) | `/tmp` |
| Valkey | None (immich cache) | `/tmp` |

### 4.3 Environment Variables

| Service | Key Env Vars | Passthrough Required? |
|---------|--------------|----------------------|
| Forgejo | `FORGEJO__*`, `USER`, `USER_UID`, `USER_GID` | ✅ Yes |
| Keycloak | `KC_*`, `JAVA_OPTS` | ✅ Yes |
| Grafana | `GF_*` | ✅ Yes |
| Redis | `REDIS_*` | ✅ Yes |
| Valkey | None | ✅ Yes |

---

## 5. Testing Plan

### 5.1 Unit Tests (Per Service)

| Test | Pass Criteria |
|------|---------------|
| Container starts | `docker ps` shows running |
| Health check passes | `shim healthcheck --tcp` returns 0 |
| Service responds | HTTP/TCP check on service port |
| Volumes mount | Data persists after restart |
| Environment vars pass through | Service reads config correctly |

### 5.2 Integration Tests (Cross-Service)

| Test | Pass Criteria |
|------|---------------|
| Forgejo ↔ PostgreSQL | Forgejo can create repos |
| Keycloak ↔ PostgreSQL | Keycloak can initialize DB |
| Grafana ↔ Prometheus | Grafana can query Prometheus |
| Redis ↔ redis-exporter | Exporter can connect to Redis |
| Valkey ↔ immich | Immich can use valkey for caching |

### 5.3 Regression Tests

| Test | Pass Criteria |
|------|---------------|
| No alerting regression | Alertmanager still sends alerts |
| No dashboard regression | Grafana dashboards still display |
| No SSH regression | Forgejo SSH access works |
| No OIDC regression | Keycloak login still works |

---

## 6. Rollback Plan

### Per-Service Rollback

1. Stop EIR service
2. Restore SIS compose file from git
3. Start SIS service
4. Verify service works
5. Document issue

### Full Rollback

1. `git checkout main -- stacks/`
2. `docker compose down`
3. `docker compose up -d`
4. Verify all services work

---

## 7. Timeline

| Day | Services | Effort |
|-----|----------|--------|
| Day 1 | Redis, Valkey | 30 min |
| Day 2 | Forgejo | 30 min |
| Day 3 | Grafana | 45 min |
| Day 4 | Keycloak | 45 min |
| Day 5 | Monitoring + verification | 30 min |

**Total: 5 days, ~3 hours of active work**

---

## 8. Success Criteria

- [ ] All 5 services migrated and running
- [ ] All health checks passing
- [ ] All dependent services working
- [ ] No alerting regressions
- [ ] No dashboard regressions
- [ ] No SSH regressions
- [ ] No OIDC regressions
- [ ] 24-hour monitoring period completed
- [ ] Documentation updated
