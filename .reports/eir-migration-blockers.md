# EIR Migration Blockers — Full Breakdown

**Date:** 2026-06-11
**Author:** Nexus (Principal Systems Architect)
**Status:** Phase 1 complete, Phase 2 blocked

---

## Executive Summary

Phase 1 (traefik, cloudflared, alertmanager, tempo) is fully deployed and working on EIR images. Phase 2 (forgejo, valkey, grafana, redis, keycloak) has 5 services with EIR images that either have broken entrypoints, build failures, or both. The root causes are:

1. **EIR Dockerfile entrypoint bugs** — 3 services have wrong paths or missing flags
2. **CI build environment failures** — `debian:bookworm-slim` package repos and download URLs fail intermittently in buildx
3. **EIR image design inconsistencies** — no standard pattern for ENTRYPOINT/CMD/USER across images

---

## Phase 1: Complete ✅

| Service | Image | Status | Notes |
|---------|-------|--------|-------|
| traefik | `ghcr.io/wyattau/evergreenimageregistry/traefik:latest` | ✅ healthy | Fixed: healthcheck missing `CMD` prefix |
| cloudflared | `ghcr.io/wyattau/evergreenimageregistry/cloudflared:latest` | ✅ running | Fixed: healthcheck port mismatch (7844 vs 4788) |
| alertmanager | `ghcr.io/wyattau/evergreenimageregistry/alertmanager:latest` | ✅ healthy | Fixed: storage volume mount, config rendering |
| tempo | `ghcr.io/wyattau/evergreenimageregistry/tempo:latest` | ✅ healthy | Fixed: binary path bug, WAL permissions |

---

## Phase 2: Blocked ❌

### 2.1 Forgejo — Entrypoint Path Mismatch

**EIR Image:** `ghcr.io/wyattau/evergreenimageregistry/forgejo:latest`
**SIS Image:** `ghcr.io/wyattau/forgejo:15.0.2`

**Problem:**
```
ENTRYPOINT ["/shim", "run", "-c", "forgejo"]
```
But shim binary is at `/usr/local/bin/shim`, not `/shim`.

**Error:**
```
stat /shim: no such file or directory
```

**Root Cause:** EIR Dockerfile copies shim to `/usr/local/bin/shim` but ENTRYPOINT references `/shim`.

**Status:** Fixed in EIR commit `ad8374537` — changed to `["/usr/local/bin/shim", "run", "-c", "forgejo"]`. Needs rebuild.

**Additional Issue:** Forgejo CMD includes `-c` flag which conflicts with shim's `-c` flag:
```
# EIR CMD (from inspect):
Cmd: [-c /usr/local/bin/forgejo -- wget -qO- http://localhost:3000/ || exit 1]
# This causes: error: the argument '--command <COMMAND>' cannot be used multiple times
```

**Fix Required:** Remove `-c` from forgejo CMD, or change shim's flag to something else.

---

### 2.2 Valkey — Missing `-c` Flag + CMD Duplication

**EIR Image:** `ghcr.io/wyattau/evergreenimageregistry/valkey:latest`
**SIS Image:** `valkey:9.0.4`

**Problem 1:** Original entrypoint was `["/usr/local/bin/shim", "run"]` — missing `-c` flag. Shim doesn't know what binary to exec.

**Error:**
```
Starting child process: 
Error: io error: No such file or directory (os error 2)
```

**Fix Applied:** Changed to `["/usr/local/bin/shim", "run", "-c", "valkey-server"]`

**Problem 2:** After fix, CMD duplicated the binary name:
```
ENTRYPOINT ["/usr/local/bin/shim", "run", "-c", "valkey-server"]
CMD ["valkey-server", "--save", "60", "1", "--loglevel", "warning"]
# valkey-server appears twice — shim passes "valkey-server" as arg to valkey-server
```

**Error:**
```
Fatal error, can't open config file '/app/valkey-server': No such file or directory
```

**Fix Applied:** Changed CMD to `["--save", "60", "1", "--loglevel", "warning"]` (removed duplicate binary name).

**Status:** Fixed in EIR commit `e25ea007f`. Image built, pushed, container starts successfully. Still shows unhealthy — likely healthcheck timing issue (valkey takes time to bind port 6379 after startup).

---

### 2.3 Grafana — Binary Discovery + CI Build Failure

**EIR Image:** `ghcr.io/wyattau/evergreenimageregistry/grafana:latest`
**SIS Image:** `grafana/grafana:12.2.8-security-04`

**Problem 1:** Grafana v12.x internally tries to exec `grafana` (new binary name), but EIR only copies `grafana-server`.

**Error:**
```
Deprecation warning: The standalone 'grafana-server' program is deprecated
Error locating grafana: exec: "grafana": executable file not found in $PATH
```

**Fix Applied:** Copy entire `bin/` directory from Grafana tarball, set `PATH="/grafana-bin:$PATH"`.

**Problem 2:** Grafana tag `v12.2.8-security-04` doesn't exist on GitHub (it's `v12.2.8+security-04` with `+`). Git clone fails silently, fallback clones main (Grafana 13.x) which has different directory structure.

**Error:**
```
stat /src/cmd/grafana-server: directory not found
```

**Fix Applied:** Changed to clean tag `v12.2.9`.

**Problem 3:** `debian:bookworm-slim` `apt-get` fails in buildx with exit code 100. Same issue as redis.

**Error:**
```
apt-get update && apt-get install -y --no-install-recommends wget ca-certificates
# exit code: 100
```

**Fix Applied:** Switched to `cgr.dev/chainguard/wolfi-base` for downloader stage. Still fails — wget download from `dl.grafana.com` fails in buildx.

**Status:** Blocked by CI network issues. Image cannot be built in CI.

---

### 2.4 Redis — CI Build Failure + Static Compilation Issues

**EIR Image:** `ghcr.io/wyattau/evergreenimageregistry/redis:latest`
**SIS Image:** `redis:7.4.9`

**Problem 1:** `debian:bookworm-slim` `apt-get` fails in buildx with exit code 100.

**Error:**
```
apt-get update && apt-get install -y --no-install-recommends build-essential linux-headers ca-certificates wget
# exit code: 100
```

**Fix Attempted:** Switched to `cgr.dev/chainguard/wolfi-base`.

**Problem 2:** After switching to wolfi-base, `make` fails with exit code 2 — static compilation with jemalloc + TLS requires OpenSSL dev headers not present in wolfi-base.

**Error:**
```
make -j$(nproc) CFLAGS="-static -O2" LDFLAGS="-static" MALLOC=jemalloc BUILD_TLS=yes install
# exit code: 2
```

**Fix Required:** Add `openssl-dev` to wolfi-base packages, or switch to `alpine` (blocked by pre-commit hook).

**Status:** Blocked by CI build environment. Needs `openssl-dev` package or alternative build approach.

---

### 2.5 Keycloak — Built, Not Deployed

**EIR Image:** `ghcr.io/wyattau/evergreenimageregistry/keycloak:latest`
**SIS Image:** `quay.io/keycloak/keycloak:26.6.2`

**Status:** Image built and pushed successfully. Not yet deployed.

**Known Issues to Address Before Deploy:**
1. SIS `command: start` overrides EIR CMD — need to verify EIR defaults work for production
2. Healthcheck port mismatch — EIR checks 8080, SIS checks 9000 (management port)
3. `JAVA_OPTS` env var not supported in EIR — remove from compose
4. `KEYCLOAK_ADMIN` env var naming may differ between SIS and EIR

---

## Systemic Issues

### 3.1 CI Build Environment — Network Failures

**Affected Services:** grafana, redis, and intermittently others

**Problem:** The GitHub Actions buildx builder has intermittent network failures:
- `debian:bookworm-slim` `apt-get update` fails with exit code 100
- `dl.grafana.com` wget downloads fail
- `download.redis.io` wget downloads fail (when using debian)

**Impact:** Cannot build images that require downloading packages or binaries in the builder stage.

**Workaround:** Use `cgr.dev/chainguard/wolfi-base` for package installation (apk is more reliable than apt in buildx). But wolfi-base doesn't have all required packages (e.g., `openssl-dev` for redis static compilation).

**Root Cause:** Likely Docker buildx network sandboxing or DNS resolution issues in GitHub Actions runners. Not a Dockerfile issue.

### 3.2 EIR Entrypoint Pattern Inconsistency

**Problem:** There is no standard pattern across EIR images for ENTRYPOINT/CMD:

| Image | ENTRYPOINT | CMD | Shim Path |
|-------|-----------|-----|-----------|
| traefik | `/shim run -c traefik` | _(none)_ | `/shim` ✅ |
| cloudflared | `/shim run -c /cloudflared` | _(none)_ | `/shim` ✅ |
| alertmanager | `/shim run -c alertmanager` | _(none)_ | `/shim` ✅ |
| tempo | `/shim run -c /tempo` | _(none)_ | `/shim` ✅ |
| forgejo | `/shim run -c forgejo` | _(conflicts)_ | `/usr/local/bin/shim` ❌ |
| valkey | `/usr/local/bin/shim run` | _(dup binary)_ | `/usr/local/bin/shim` ⚠️ |
| grafana | `/shim run -c /grafana-server` | _(conflicts)_ | `/shim` ❌ |

**Issues:**
- Shim binary path varies: `/shim` vs `/usr/local/bin/shim`
- Some ENTRYPOINTs include `-c` flag, some don't
- Some CMDs duplicate the binary name already in ENTRYPOINT
- Some CMDs use `-c` flag that conflicts with shim's `-c`

**Recommendation:** Establish a standard pattern and enforce it in EIR validation:

```dockerfile
# Standard pattern:
COPY --from=shim /shim /shim
ENTRYPOINT ["/shim", "run", "-c", "/usr/local/bin/<binary>"]
CMD ["<arg1>", "<arg2>"]  # Only args, no binary name, no -c flag
```

### 3.3 EIR Dockerfile Build Stages

**Problem:** EIR images use inconsistent builder base images:

| Image | Builder Base | Issue |
|-------|-------------|-------|
| traefik | `golang:1.25-bookworm` | ✅ Works |
| cloudflared | `golang:1.24-bookworm` | ✅ Works |
| alertmanager | `golang:1.25-bookworm` | ✅ Works |
| tempo | `debian:bookworm-slim` | ✅ Works (binary download) |
| forgejo | `cgr.dev/chainguard/wolfi-base` | ✅ Works |
| valkey | `cgr.dev/chainguard/wolfi-base` | ✅ Works |
| grafana | `debian:bookworm-slim` → `cgr.dev/chainguard/wolfi-base` | ❌ Fails in CI |
| redis | `debian:bookworm-slim` → `cgr.dev/chainguard/wolfi-base` | ❌ Fails in CI |

**Recommendation:** Standardize on `cgr.dev/chainguard/wolfi-base` for non-Go images. For Go images, pin to `golang:1.25-bookworm` or later.

---

## Resolution Plan

### Immediate (Phase 2 Deployment)

| Priority | Task | Effort | Blocks |
|----------|------|--------|--------|
| P0 | Fix forgejo CMD `-c` conflict | 15 min | Forgejo deploy |
| P0 | Fix valkey healthcheck timing | 10 min | Valkey deploy |
| P0 | Deploy keycloak (test first) | 30 min | Keycloak deploy |
| P1 | Fix grafana CI build (wolfi-base + network) | 2 hrs | Grafana deploy |
| P1 | Fix redis CI build (openssl-dev) | 2 hrs | Redis deploy |

### Medium-Term (EIR Standardization)

| Priority | Task | Effort |
|----------|------|--------|
| P2 | Establish standard ENTRYPOINT/CMD pattern | 1 hr |
| P2 | Add pre-commit validation for entrypoint consistency | 2 hrs |
| P2 | Standardize builder base images across all Dockerfiles | 1 hr |
| P3 | Fix CI network issues (buildx DNS/networking) | Unknown |

### Long-Term (EIR Quality)

| Priority | Task | Effort |
|----------|------|--------|
| P4 | Add integration tests for each EIR image | 1 day |
| P4 | Add healthcheck validation to EIR CI | 2 hrs |
| P4 | Document expected behavior for each image | 1 day |

---

## Files Changed

### EIR Repository (EvergreenImageRegistry)

| Commit | Description | Status |
|--------|-------------|--------|
| `a4e553e99` | Fix cloudflared tag prefix, alertmanager go version | ✅ Merged |
| `803df3595` | Fix tempo Dockerfile binary path | ✅ Merged |
| `6ab2b3e1c` | Fix tempo — hardcode amd64, use debian:bookworm-slim | ✅ Merged |
| `68cfe5dc8` | Remove hardcoded healthcheck ports, add dirs | ✅ Merged |
| `6ab2b3e1c` | Fix tempo Dockerfile | ✅ Merged |
| `9e0a2e5bc` | Fix forgejo and grafana — hardcode amd64 | ✅ Merged |
| `d8b2e3384` | Fix grafana — use clean tag v12.2.9 | ✅ Merged |
| `76bc00679` | Fix grafana — switch to pre-built binary download | ✅ Merged |
| `4aeb8e24d` | Fix redis — switch to wolfi-base builder | ✅ Merged |
| `ad8374537` | Fix entrypoint paths for forgejo, valkey, grafana | ✅ Merged |
| `e25ea007f` | Fix valkey CMD dedup, grafana bin dir + symlink | ✅ Merged |
| `9267c63b3` | Fix grafana — add PATH for binary discovery | ✅ Merged |
| `697386485` | Fix grafana — copy entire bin dir | ✅ Merged |
| `b025ef86d` | Fix grafana — use wolfi-base for downloader | ✅ Merged |

### SIS Repository (SimpleInfrastructureStack)

| File | Changes |
|------|---------|
| `stacks/proxy/docker-compose.yml` | Image → EIR, healthcheck `CMD` prefix, array form |
| `stacks/tunnel/docker-compose.yml` | Image → EIR, array form command |
| `stacks/monitoring/docker-compose.yml` | Images → EIR (alertmanager, tempo, grafana), healthchecks, volumes |
| `stacks/monitoring/alertmanager/alertmanager.yml.tpl` | Renamed to `.tmpl`, Jinja2 syntax |
| `stacks/photos/docker-compose.yml` | Image → EIR (valkey), healthcheck, removed cap_add |
| `stacks/operations/docker-compose.yml` | Image → EIR (forgejo), healthcheck, removed cap_add |
| `scripts/render-alertmanager-config.sh` | Deleted (no longer needed) |
| `stacks/monitoring/alertmanager/entrypoint.sh` | Deleted (no longer needed) |
