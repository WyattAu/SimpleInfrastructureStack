# SIS Stack → EvergreenImageRegistry Migration Analysis

**Date:** 2026-06-09
**Author:** Nexus (Principal Systems Architect)
**Status:** Analysis Complete — Migration Blocked on Multiple Fronts

---

## Executive Summary

The SimpleInfrastructureStack (SIS) uses **53 unique Docker images** across 21 stacks. The EvergreenImageRegistry (EIR) provides hardened versions of many of these images, but migration is blocked by **five fundamental incompatibilities** that prevent a drop-in replacement.

**Bottom line:** ~40% of SIS images have matching EIR versions, but the health-shim wrapper, read-only rootfs, scratch-based bases, and entrypoint conflicts make migration non-trivial. A phased approach starting with low-risk services is recommended.

---

## 1. The Health-Shim Wrapper Problem

### What EIR Does

Every EIR image wraps the application with a Go binary called `health-shim` that acts as PID 1:

```dockerfile
# EIR pattern
ENTRYPOINT ["/shim", "run", "-c", "app-binary"]
CMD ["-c", "redis-server", "--", "--bind", "0.0.0.0"]
```

This provides:
- Structured healthchecks (TCP/HTTP probes)
- Prometheus metrics on port 9101/9102
- Graceful shutdown handling
- Management API

### Why This Breaks SIS

SIS compose files use standard upstream entrypoints:

```yaml
# SIS pattern
services:
  redis:
    image: redis:${REDIS_VERSION}-alpine
    command: redis-server --appendonly yes
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
```

With EIR images, the shim becomes PID 1 and the application runs as a child process. This means:

1. **`command:` overrides may conflict** — The shim wraps the command, so `command: redis-server --appendonly yes` gets passed through the shim's `-c` flag. If the shim expects a specific command format, this breaks.

2. **Healthcheck definitions change** — SIS uses `CMD-SHELL` or `CMD` healthchecks. EIR uses the shim's built-in healthcheck. You'd need to either:
   - Remove the compose-level `healthcheck:` (let the shim handle it)
   - Or override with a shim-compatible format

3. **Entrypoint/CMD interaction** — EIR images use `ENTRYPOINT ["/shim", "run", "-c", "app"]` with `CMD ["-c", "app-binary", "--", "args"]`. SIS compose files that override `entrypoint:` or `cmd:` would bypass the shim entirely.

### Affected Services

| Service | SIS Command Pattern | EIR Shim Pattern | Conflict Risk |
|---------|---------------------|------------------|---------------|
| redis | `redis-server --appendonly yes` | `["-c", "redis-server", "--", "--bind", "0.0.0.0"]` | **HIGH** |
| postgres | `postgres` (via env vars) | `["-c", "docker-entrypoint.sh", "--", "postgres"]` | **HIGH** |
| grafana | `/run.sh` (custom entrypoint) | `["/shim", "run", "-c", "grafana-server"]` | **HIGH** |
| traefik | `/entrypoint.sh` (custom) | `["/shim", "run", "-c", "traefik"]` | **MEDIUM** |
| keycloak | `start-dev` | `["/shim", "run", "-c", "keycloak"]` | **MEDIUM** |

---

## 2. The Read-Only Root Filesystem Problem

### What EIR Does

Every EIR image enforces `read-only-rootfs: true` via Docker security options:

```dockerfile
LABEL evergreen.security.read-only-rootfs="true"
```

### Why This Breaks SIS

Many SIS services write to the filesystem at runtime:

| Service | Writable Path | Purpose | SIS Compose Volume? |
|---------|---------------|---------|---------------------|
| Grafana | `/var/lib/grafana` | Plugins, dashboards, SQLite DB | ✅ Yes |
| PostgreSQL | `/var/lib/postgresql/data` | Database files | ✅ Yes |
| Redis | `/data` | AOF/RDB persistence | ✅ Yes |
| Forgejo | `/data` | Repositories, LFS, config | ✅ Yes |
| Uptime Kuma | `/app/data` | SQLite DB, config | ❌ No |
| Paperless | `/var/lib/paperless` | Documents, SQLite DB | ✅ Yes |
| Keycloak | `/opt/keycloak/data` | Realm configs | ❌ No |

### The Problem

Even with volumes mounted, some services need writable temporary paths:
- `/tmp` for process temporary files
- `/run` for PID files, sockets
- `/var/cache` for application caches
- `/var/log` for log files

With `read-only-rootfs`, these paths are read-only unless you explicitly add `tmpfs` mounts:

```yaml
# Required for every EIR service
services:
  grafana:
    image: ghcr.io/wyattau/evergreenimageregistry/grafana:12.2.8-security-04
    read_only: true
    tmpfs:
      - /tmp
      - /run
      - /var/lib/grafana
      - /var/cache
```

This is a **significant compose file change** across all 21 stacks.

---

## 3. The Scratch-Based Base Problem

### What EIR Does

Many EIR images use `scratch` as the final stage — the most minimal possible base:

```dockerfile
FROM scratch
COPY --from=shim /shim /shim
COPY --from=builder /grafana-server /grafana-server
USER 65532:65532
ENTRYPOINT ["/shim", "run", "-c", "grafana-server"]
```

### Why This Breaks SIS

Scratch-based images have **no shell, no package manager, no debugging tools**:

| Capability | Upstream Image | EIR Scratch Image |
|------------|----------------|-------------------|
| `docker exec -it container sh` | ✅ Works | ❌ No shell |
| `docker exec container ls /app` | ✅ Works | ❌ No ls binary |
| `command: sh -c "echo test"` | ✅ Works | ❌ No sh |
| Shell-based healthchecks | ✅ Works | ❌ No shell |
| Custom init scripts | ✅ Works | ❌ No shell |

### Specific Breakage Points

**1. Debugging becomes impossible**
```bash
# With upstream image
docker exec -it monitoring-grafana sh
# ls /var/lib/grafana/plugins/
# cat /etc/grafana/grafana.ini

# With EIR scratch image
docker exec -it monitoring-grafana sh
# exec: "sh": executable file not found in $PATH
```

**2. Shell-based healthchecks fail**
```yaml
# SIS healthcheck (works with upstream)
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]

# EIR healthcheck (uses shim, no shell needed)
healthcheck:
  test: ["/usr/local/bin/shim", "healthcheck", "--tcp", "127.0.0.1:5432"]
```

**3. Custom commands break**
```yaml
# SIS custom command
command: sh -c "sleep 10 && redis-cli FLUSHALL"

# EIR scratch image — sh doesn't exist
command: sh -c "sleep 10 && redis-cli FLUSHALL"
# Error: exec: "sh": executable file not found in $PATH
```

### Affected SIS Images (EIR Scratch-Based)

| Image | SIS Base | EIR Base | Shell Available? |
|-------|----------|----------|------------------|
| grafana | debian | scratch | ❌ No |
| traefik | alpine | scratch | ❌ No |
| redis | alpine | scratch | ❌ No |
| forgejo-runner | scratch | scratch | ❌ No |
| blackbox-exporter | — | scratch | ❌ No |
| node-exporter | — | scratch | ❌ No |

---

## 4. The Entrypoint/CMD Conflict Problem

### What EIR Does

EIR images have a specific entrypoint structure:

```dockerfile
ENTRYPOINT ["/shim", "run", "-c", "app-binary"]
CMD ["-c", "app-binary", "--", "default-args"]
```

### Why This Breaks SIS

SIS compose files override `command:` and `entrypoint:` in ways that conflict:

**Example 1: Forgejo**
```yaml
# SIS compose
services:
  forgejo:
    image: ghcr.io/wyattau/forgejo:15.0.2
    command: server --config /etc/forgejo/app.ini

# EIR image
ENTRYPOINT ["/shim", "run", "-c", "forgejo"]
CMD ["-c", "/usr/local/bin/forgejo", "--", "wget -qO- http://localhost:3000/ || exit 1"]
```

The SIS `command: server --config ...` would be passed through the shim's `-c` flag. If the shim expects a specific format (like `["-c", "forgejo"]`), this breaks.

**Example 2: Grafana**
```yaml
# SIS compose
services:
  grafana:
    image: grafana/grafana:12.2.8-security-04
    entrypoint: ["/run.sh"]
    volumes:
      - ./grafana/run.sh:/run.sh:ro

# EIR image
ENTRYPOINT ["/shim", "run", "-c", "grafana-server"]
```

The SIS `entrypoint: ["/run.sh"]` would bypass the shim entirely, losing healthchecks and metrics.

**Example 3: PostgreSQL**
```yaml
# SIS compose
services:
  postgres:
    image: postgres:17.10
    environment:
      - POSTGRES_DB=mydb
      - POSTGRES_USER=admin
      - POSTGRES_PASSWORD=secret

# EIR image
ENTRYPOINT ["/shim", "run", "-c", "postgres"]
CMD ["-c", "docker-entrypoint.sh", "--", "postgres"]
```

The upstream `postgres` image uses `docker-entrypoint.sh` which reads `POSTGRES_*` env vars. The EIR image wraps this with the shim. If the shim's CMD format doesn't pass through the entrypoint script correctly, initialization breaks.

---

## 5. The Capability/Device Access Problem

### What EIR Does

EIR drops ALL Linux capabilities:

```dockerfile
LABEL evergreen.security.cap-drop="ALL"
```

### Why This Breaks SIS

Some SIS services need specific capabilities:

| Service | Required Capability | Purpose | EIR Allows? |
|---------|---------------------|---------|-------------|
| cadvisor | `SYS_ADMIN` | cgroup access | ❌ No |
| docker-socket-proxy | Docker socket mount | Docker API access | ⚠️ Partial |
| wireguard | `NET_ADMIN` | Network interface config | ❌ No |
| crowdsec | `NET_RAW` | Packet inspection | ❌ No |
| node-exporter | `/proc`, `/sys` mounts | Host metrics | ⚠️ Partial |

### Specific Breakage Points

**cadvisor** needs Docker socket access and cgroup mounts:
```yaml
# SIS compose
services:
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.55.1
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    privileged: false  # SIS doesn't use privileged, but needs SYS_ADMIN

# EIR image — CAP_DROP ALL means no SYS_ADMIN
# cAdvisor won't be able to read cgroup stats
```

**wireguard** needs `NET_ADMIN` for creating network interfaces:
```yaml
# SIS compose
services:
  wireguard:
    image: linuxserver/wireguard:1.0.20250521
    cap_add:
      - NET_ADMIN

# EIR image — CAP_DROP ALL, no NET_ADMIN
# WireGuard can't create tun interfaces
```

---

## 6. Version Compatibility Matrix

### ✅ Direct Drop-in (Same Version, Compatible Base)

| Image | SIS Version | EIR Version | EIR Base | Risk |
|-------|-------------|-------------|----------|------|
| forgejo | 15.0.2 | 15.0.2 | wolfi | Low |
| traefik | v3.7.1 | v3.7.1 | scratch | Low |
| keycloak | 26.6.2 | 26.6.2 | wolfi | Low |
| cloudflared | 2026.5.0 | 2026.5.0 | scratch | Low |
| grafana | 12.2.8-security-04 | 12.2.8-security-04 | scratch | Medium |
| alertmanager | v0.32.1 | v0.32.1 | scratch | Low |
| tempo | 2.10.5 | 2.10.5 | scratch | Low |
| victoria-logs | v1.50.0 | v1.50.0 | scratch | Low |

### ⚠️ Conditional (Version Close, Needs Testing)

| Image | SIS Version | EIR Version | EIR Base | Issue |
|-------|-------------|-------------|----------|-------|
| postgres | 17.10 | 17.10 | wolfi | Different entrypoint (shim + docker-entrypoint.sh) |
| redis | 7.4.9-alpine | 7.4.1 | scratch | EIR slightly older, no shell |
| node-exporter | v1.11.1 | v1.11.1 | scratch | Needs /proc, /sys mounts |
| cadvisor | v0.55.1 | v0.57.0 | wolfi | EIR newer, needs Docker socket |
| paperless-ngx | 2.20.15 | 2.20.15 | wolfi | Needs s6-overlay, tesseract, poppler |
| valkey | 9.0.4 | 9.0.4 | scratch | Needs verification |
| uptime-kuma | 2.3.2 | 2.3.2 | wolfi | Needs Node.js + npm for plugins |
| nginx | 1.27.1 | 1.27.1 | wolfi | Needs verification |
| immich-ml | v2.7.5 | 2.7.5 | wolfi | Needs verification |

### ❌ No EIR Image Available

| Image | Stack | Reason |
|-------|-------|--------|
| victoriametrics/vmalert | monitoring | Not in EIR |
| prom/blackbox-exporter | monitoring | Not in EIR |
| quay.io/oauth2-proxy/oauth2-proxy | proxy | Not in EIR |
| tecnativa/docker-socket-proxy | proxy | Not in EIR |
| frappe/erpnext | erpnext | Not in EIR |
| mariadb | erpnext, accounting | Not in EIR |
| taigaio/* (4 images) | project-management | Not in EIR |
| akaunting/akaunting | accounting | Not in EIR |
| gethomepage/homepage | utility | Not in EIR |
| matrixdotorg/synapse | collaboration | Not in EIR |
| vectorim/element-web | collaboration | Not in EIR |
| owncloud/ocis | storage | Not in EIR |
| collabora/code | storage | Not in EIR |
| freshrss/freshrss | rss | Not in EIR |
| linuxserver/wireguard | vpn | Not in EIR |
| containrrr/watchtower | updater | Not in EIR |
| restic/restic | backup | Not in EIR |
| crowdsecurity/crowdsec | security | Not in EIR |

### ❌ EIR Version Older Than SIS

| Image | SIS Version | EIR Version | Delta |
|-------|-------------|-------------|-------|
| postgresql-exporter | v0.19.1 | 0.15.0 | 4 versions behind |
| redis | 7.4.9 | 7.4.1 | Minor behind |
| immich | v2.7.5 | 1.106.0 | Ancient (v1 vs v2) |

---

## 7. Migration Effort Estimate

### Per-Stack Effort

| Stack | Images | EIR Compatible? | Effort | Notes |
|-------|--------|-----------------|--------|-------|
| operations | 3 | 2/3 | **Medium** | Forgejo + Postgres need entrypoint testing |
| monitoring | 13 | 8/13 | **High** | Many images, need mount point testing |
| proxy | 3 | 1/3 | **Low** | Only Traefik migrates |
| photos | 4 | 1/4 | **Low** | Immich version ancient, keep upstream |
| documents | 3 | 2/3 | **Medium** | Paperless needs s6-overlay testing |
| iam | 2 | 2/2 | **Medium** | Keycloak + Postgres need entrypoint testing |
| tunnel | 1 | 1/1 | **Low** | Direct drop-in |
| erpnext | 4 | 0/4 | **None** | No EIR images |
| project-management | 5 | 0/5 | **None** | No EIR images |
| collaboration | 4 | 0/4 | **None** | No EIR images |
| rss | 2 | 0/2 | **None** | No EIR images |
| storage | 2 | 0/2 | **None** | No EIR images |
| vaultwarden | 1 | 0/1 | **None** | No EIR image |
| updater | 1 | 0/1 | **None** | No EIR image |
| backup | 1 | 0/1 | **None** | No EIR image |
| security | 2 | 0/2 | **None** | No EIR images |
| vpn | 1 | 0/1 | **None** | No EIR image |
| utility | 1 | 0/1 | **None** | No EIR image |
| accounting | 3 | 0/3 | **None** | No EIR images |
| books | 2 | 0/2 | **None** | No EIR image |

### Total Effort

| Category | Count | Effort |
|----------|-------|--------|
| Direct drop-in (Low risk) | 8 images | ~2 hours |
| Needs testing (Medium risk) | 9 images | ~8 hours |
| No EIR equivalent | 36 images | 0 hours (keep upstream) |
| **Total migration** | **17 images** | **~10 hours** |

---

## 8. Recommended Migration Strategy

### Phase 1: Validate Pattern (Low Risk, High Value)

Migrate 4 services that are scratch-based, same version, minimal config:

1. **traefik** — Most critical, validates shim pattern
2. **cloudflared** — Simple, validates shim pattern
3. **alertmanager** — Simple, validates shim pattern
4. **tempo** — Simple, validates shim pattern

**Validation criteria:**
- [ ] Healthchecks work via shim
- [ ] Prometheus metrics exposed on :9101
- [ ] No breaking changes to SIS compose files
- [ ] Traefik routing unaffected

### Phase 2: Validate Complex Services (Medium Risk)

Migrate 5 services that need entrypoint/volume testing:

1. **forgejo** — Test entrypoint, volumes, SSH
2. **keycloak** — Test entrypoint, database init
3. **grafana** — Test plugin loading, dashboard volumes
4. **redis** — Test command overrides, persistence
5. **valkey** — Test compatibility

**Validation criteria:**
- [ ] Entrypoint works with SIS command overrides
- [ ] Volumes mount correctly with read-only rootfs
- [ ] tmpfs mounts added for writable paths
- [ ] All environment variables pass through correctly

### Phase 3: Validate High-Risk Services (High Risk)

Migrate 4 services that need mount/capability testing:

1. **postgres** — Test init scripts, extensions
2. **node-exporter** — Test /proc, /sys mounts
3. **cadvisor** — Test Docker socket access
4. **paperless-ngx** — Test s6-overlay, tesseract, poppler

**Validation criteria:**
- [ ] All mount points work correctly
- [ ] Capabilities are sufficient
- [ ] No regression in functionality

### Phase 4: Keep Upstream (No Migration)

36 images have no EIR equivalent or EIR version is too old. Keep upstream:

- ERPNext, MariaDB, Taiga, Akaunting, Homepage
- Immich (main — EIR version ancient)
- vmalert, blackbox-exporter, oauth2-proxy
- Synapse, Element, WireGuard, CrowdSec

---

## 9. Specific Blockers Requiring Resolution

### Blocker 1: Health-Shim Entrypoint Format

**Question:** How does the shim handle `command:` overrides from compose?

**Test needed:**
```bash
# Test 1: Does this work?
docker run --rm ghcr.io/wyattau/evergreenimageregistry/redis:8.6 \
  -c "redis-server --appendonly yes"

# Test 2: Or do we need?
docker run --rm -e SHIM_CMD="redis-server --appendonly yes" \
  ghcr.io/wyattau/evergreenimageregistry/redis:8.6
```

### Blocker 2: Read-Only Root Filesystem Compatibility

**Question:** Which services need tmpfs mounts for writable paths?

**Test needed:** Run each service with `--read-only` and identify failure paths:
```bash
docker run --rm --read-only \
  --tmpfs /tmp \
  --tmpfs /run \
  ghcr.io/wyattau/evergreenimageregistry/grafana:12.2.8-security-04
```

### Blocker 3: Scratch Image Debugging

**Question:** How do we debug scratch-based EIR images in production?

**Options:**
1. Use `docker logs` (if application logs to stdout)
2. Use the shim's management API on :9102
3. Maintain a "debug" variant with busybox shell
4. Accept reduced debuggability

### Blocker 4: Capability Requirements

**Question:** Which services need specific capabilities that EIR drops?

**Test needed:** Run each service with `--cap-drop ALL` and identify failures:
- cadvisor: needs `SYS_ADMIN`
- wireguard: needs `NET_ADMIN`
- crowdsec: needs `NET_RAW`

### Blocker 5: Immich Version Gap

**Question:** EIR's immich is v1.106.0, SIS uses v2.7.5. Can we skip?

**Answer:** Yes — EIR's immich is too old. Keep upstream immich images.

---

## 10. Conclusion

Migration is **possible but non-trivial**. The biggest obstacles are:

1. **Health-shim wrapper** — Changes entrypoint/CMD structure for all services
2. **Read-only rootfs** — Requires tmpfs mounts for writable paths
3. **Scratch-based images** — No shell for debugging
4. **Capability drops** — Breaks cadvisor, wireguard, crowdsec
5. **36 images with no EIR equivalent** — Can't migrate those at all

**Recommendation:** Proceed with Phase 1 (4 low-risk services) to validate the pattern, then decide on Phase 2-3 based on results. The health-shim pattern is the single biggest risk factor — if it works cleanly with SIS compose files, migration becomes much more feasible.

---

## Appendix A: SIS Image Inventory

| # | Image | Stack |
|---|-------|-------|
| 1 | busybox:1.37.0 | monitoring, project-management, storage, rss, documents, collaboration |
| 2 | victoriametrics/victoria-metrics | monitoring |
| 3 | victoriametrics/vmalert | monitoring |
| 4 | grafana/grafana | monitoring |
| 5 | victoriametrics/victoria-logs | monitoring |
| 6 | grafana/promtail | monitoring |
| 7 | louislam/uptime-kuma | monitoring |
| 8 | gcr.io/cadvisor/cadvisor | monitoring |
| 9 | prom/node-exporter | monitoring |
| 10 | prom/alertmanager | monitoring |
| 11 | quay.io/prometheuscommunity/postgres-exporter | monitoring |
| 12 | oliver006/redis_exporter | monitoring |
| 13 | grafana/tempo | monitoring |
| 14 | quay.io/prometheus/blackbox-exporter | monitoring |
| 15 | ghcr.io/frebib/zfs-exporter | monitoring |
| 16 | postgres | operations, project-management, rss, documents, collaboration, iam |
| 17 | ghcr.io/wyattau/forgejo | operations |
| 18 | ghcr.io/wyattau/forgejo-runner | operations |
| 19 | taigaio/taiga-back | project-management |
| 20 | taigaio/taiga-front | project-management |
| 21 | taigaio/taiga-events | project-management |
| 22 | taigaio/taiga-protected | project-management |
| 23 | rabbitmq | project-management |
| 24 | nginx | project-management, erpnext |
| 25 | frappe/erpnext | erpnext |
| 26 | mariadb | erpnext, accounting |
| 27 | redis | erpnext, documents |
| 28 | ghcr.io/wyattau/traefik | proxy |
| 29 | quay.io/oauth2-proxy/oauth2-proxy | proxy |
| 30 | docker.io/tecnativa/docker-socket-proxy | proxy |
| 31 | gethomepage/homepage | utility |
| 32 | owncloud/ocis | storage |
| 33 | collabora/code | storage |
| 34 | freshrss/freshrss | rss |
| 35 | ghcr.io/immich-app/immich | photos |
| 36 | ghcr.io/immich-app/immich-machine-learning | photos |
| 37 | ghcr.io/immich-app/postgres | photos |
| 38 | valkey | photos |
| 39 | ghcr.io/paperless-ngx/paperless-ngx | documents |
| 40 | matrixdotorg/synapse | collaboration |
| 41 | vectorim/element-web | collaboration |
| 42 | ghcr.io/wyattau/matrix-hookshot | collaboration |
| 43 | lscr.io/linuxserver/calibre-web | books |
| 44 | akaunting/akaunting | accounting |
| 45 | prom/mysqld-exporter | accounting |
| 46 | ghcr.io/wyattau/cloudflared | tunnel |
| 47 | vaultwarden/server | vaultwarden |
| 48 | quay.io/keycloak/keycloak | iam |
| 49 | containrrr/watchtower | updater |
| 50 | restic/restic | backup |
| 51 | crowdsecurity/crowdsec | security |
| 52 | alpine | security |
| 53 | linuxserver/wireguard | vpn |

## Appendix B: EIR Image Registry

**Registry:** `ghcr.io/wyattau/evergreenimageregistry/<image>:<version>`
**Total images:** 986
**Categories:** 16 (databases, monitoring, CI/CD, security, etc.)
**Base hierarchy:** scratch > wolfi-base > distroless

**Security guarantees:**
- Non-root execution (98.9%)
- HEALTHCHECK mandatory (99.8%)
- SBOM SPDX 2.3 (98.4%)
- Digest-pinned bases (76.4%)
- CAP_DROP ALL (100%)
- no-new-privileges (100%)
- Read-only rootfs (100%)
- No hardcoded secrets (100%)
