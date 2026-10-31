# EIR Migration Blockers: Full Breakdown
1. **EIR Dockerfile entrypoint bugs**; 3 services have wrong paths or missing flags
2. **CI build environment failures**; `debian:bookworm-slim` package repos and download URLs fail intermittently in buildx
3. **EIR image design inconsistencies**; no standard pattern for ENTRYPOINT/CMD/USER across images
### 2.1 Forgejo: Entrypoint Path Mismatch
**Status:** Fixed in EIR commit `ad8374537`; changed to `["/usr/local/bin/shim", "run", "-c", "forgejo"]`. Needs rebuild.
### 2.2 Valkey: Missing `-c` Flag + CMD Duplication
**Problem 1:** Original entrypoint was `["/usr/local/bin/shim", "run"]`; missing `-c` flag. Shim doesn't know what binary to exec.
# valkey-server appears twice: shim passes "valkey-server" as arg to valkey-server
**Status:** Fixed in EIR commit `e25ea007f`. Image built, pushed, container starts successfully. Still shows unhealthy; likely healthcheck timing issue (valkey takes time to bind port 6379 after startup).
### 2.3 Grafana: Binary Discovery + CI Build Failure
**Fix Applied:** Switched to `cgr.dev/chainguard/wolfi-base` for downloader stage. Still fails; wget download from `dl.grafana.com` fails in buildx.
### 2.4 Redis: CI Build Failure + Static Compilation Issues
**Problem 2:** After switching to wolfi-base, `make` fails with exit code 2; static compilation with jemalloc + TLS requires OpenSSL dev headers not present in wolfi-base.
### 2.5 Keycloak: Built, Not Deployed
1. SIS `command: start` overrides EIR CMD; need to verify EIR defaults work for production
2. Healthcheck port mismatch; EIR checks 8080, SIS checks 9000 (management port)
3. `JAVA_OPTS` env var not supported in EIR; remove from compose
### 3.1 CI Build Environment: Network Failures
| `6ab2b3e1c` | Fix tempo; hardcode amd64, use debian:bookworm-slim | ✅ Merged |
| `9e0a2e5bc` | Fix forgejo and grafana; hardcode amd64 | ✅ Merged |
| `d8b2e3384` | Fix grafana; use clean tag v12.2.9 | ✅ Merged |
| `76bc00679` | Fix grafana; switch to pre-built binary download | ✅ Merged |
| `4aeb8e24d` | Fix redis; switch to wolfi-base builder | ✅ Merged |
| `9267c63b3` | Fix grafana; add PATH for binary discovery | ✅ Merged |
| `697386485` | Fix grafana; copy entire bin dir | ✅ Merged |
| `b025ef86d` | Fix grafana; use wolfi-base for downloader | ✅ Merged |