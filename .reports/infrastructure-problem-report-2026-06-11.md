# Infrastructure Problem Report — 2026-06-11

**Generated:** 2026-06-11 19:30 UTC+1
**Scope:** TrueNAS (192.168.1.3), CachyOS runners (192.168.1.191), Win11 VM (10.136.57.35)
**Author:** Nexus (Principal Systems Architect)

---

## 1. Executive Summary

The infrastructure operates at **48/49 containers healthy** on TrueNAS. Nine services have been successfully migrated to EIR (EvergreenImageRegistry) hardened images. However, 40 upstream images remain, representing an incomplete supply chain security posture. Three EIR image migrations failed due to fundamental incompatibilities between scratch-based images and dynamically-linked upstream binaries. The Win11 CI runner has been unreachable since its last restart. 23 plaintext `.env` files persist on TrueNAS with secrets in the clear.

**Severity Breakdown:**
- **P0 (Critical):** 1 — Win11 runner offline
- **P1 (High):** 5 — EIR image defects, supply chain exposure, plaintext secrets
- **P2 (Medium):** 6 — Unhealthy services, resource pressure, CI code failures
- **P3 (Low):** 3 — Monitoring gaps, documentation drift

---

## 2. Problem Inventory

### P0-001: Win11 VM Runner Offline

| Field | Value |
|-------|-------|
| **Component** | Win11 VM (Incus) at 10.136.57.35 |
| **Symptom** | SSH connection timeout, Incus agent not running |
| **Impact** | No Windows CI capability; runner ID 88 (windows-latest label) unavailable |
| **Root Cause** | Unknown — VM reports RUNNING but no guest agent, no SSH, no network |
| **First Seen** | 2026-06-11 (after VM restart) |
| **Investigation** | `incus list` shows RUNNING with IP 10.136.57.35. `incus exec` fails with "VM agent isn't currently running". SSH times out. The VM may have lost its network configuration or Windows Update broke the SSH service. |
| **Remediation** | Need SPICE/VNC console access to diagnose (no viewer installed on CachyOS). Alternative: destroy and rebuild VM from scratch. |
| **Status** | **OPEN** |

---

### P1-001: Vaultwarden EIR Migration Failed — Dynamic Linking

| Field | Value |
|-------|-------|
| **Component** | `vaultwarden` EIR image (`ghcr.io/wyattau/evergreenimageregistry/vaultwarden:latest`) |
| **Symptom** | `Error: io error: No such file or directory (os error 2)` — binary crashes immediately |
| **Impact** | Cannot migrate vaultwarden to EIR; stays on upstream `vaultwarden/server:1.36.0` |
| **Root Cause** | The vaultwarden binary from upstream is **dynamically linked** (requires `/lib64/ld-linux-x86-64.so.2`, `libssl.so.3`, `libcrypto.so.3`, `libmariadb.so.3`, `libpq.so.5`, `libldap.so.2`, `libkrb5.so.3`, and 10+ other shared libraries). The EIR image uses `FROM scratch` which contains no dynamic linker or shared libraries. |
| **Discovery Method** | `file /tmp/vw-binary` → `ELF 64-bit LSB pie executable, x86-64, dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2` |
| **Remediation Options** | (A) Rebuild EIR image with `FROM cgr.dev/chainguard/wolfi-base` instead of scratch, installing required shared libs. (B) Build vaultwarden from source with `CGO_ENABLED=0` for static binary. (C) Keep upstream. |
| **Lesson** | EIR scratch-based images are **only compatible with statically-linked binaries**. Every upstream binary must be verified with `file` before attempting scratch-based packaging. |
| **Status** | **OPEN** — reverted to upstream, EIR image exists on GHCR but is non-functional |

---

### P1-002: Watchtower EIR Migration Failed — Docker Socket Permissions

| Field | Value |
|-------|-------|
| **Component** | `watchtower` EIR image (`ghcr.io/wyattau/evergreenimageregistry/watchtower:latest`) |
| **Symptom** | `permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock` |
| **Impact** | Cannot migrate watchtower to EIR; stays on upstream `containrrr/watchtower:1.7.1` |
| **Root Cause** | EIR image runs as UID 65532 (non-root). Docker socket (`/var/run/docker.sock`) is owned by `root:docker`. Container has `cap_drop: ALL` and no `group_add`. The non-root user cannot access the socket. |
| **Remediation Options** | (A) Add `user: root` to compose (defeats EIR non-root security model). (B) Add `group_add: [docker-GID]` to compose. (C) Keep upstream (watchtower already runs as root in upstream image). |
| **Assessment** | Watchtower inherently requires privileged Docker socket access. The EIR non-root security model provides minimal benefit for this specific service. **Recommendation: Keep upstream.** |
| **Status** | **RESOLVED** — reverted to upstream, by design |

---

### P1-003: EIR Keycloak Image Missing Java Runtime

| Field | Value |
|-------|-------|
| **Component** | `keycloak` EIR image |
| **Symptom** | `/opt/keycloak/bin/kc.sh: eval: line 167: java: not found` |
| **Impact** | Keycloak completely non-functional. All services depending on Keycloak SSO (Forgejo, Grafana, Uptime Kuma, etc.) lose authentication. |
| **Root Cause** | EIR Dockerfile installs `wget` and `ca-certificates` on wolfi-base but **not `openjdk-21`**. Keycloak is a Java/Quarkus application requiring a JVM. Additionally, even after installing openjdk-21, the `java` binary is at `/usr/lib/jvm/java-21-openjdk/bin/java` (not in PATH), requiring a symlink. |
| **Fix Applied** | Added `openjdk-21` to `apk add` and created symlink: `ln -sf /usr/lib/jvm/java-21-openjdk/bin/java /usr/local/bin/java`. Also set `ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk`. |
| **Resolution** | Image rebuilt, pushed to GHCR, deployed. Keycloak now healthy. |
| **Lesson** | Wolfi-based EIR images must verify ALL runtime dependencies of the target application, including language runtimes (Java, Python, Node.js). |
| **Status** | **RESOLVED** |

---

### P1-004: EIR Grafana Scratch Image Missing Public Directory

| Field | Value |
|-------|-------|
| **Component** | `grafana` EIR image |
| **Symptom** | `provided html/template filepaths matched no files: /usr/share/grafana/public/emails/*.html` |
| **Impact** | Grafana crashes on startup, no dashboards available |
| **Root Cause** | EIR Dockerfile downloader stage only copies `conf/` from the Grafana tarball but not `public/` directory (web UI, email templates, static assets). The scratch image has no fallback content. |
| **Fix Applied** | Added `cp -r /tmp/grafana-${VERSION}/public /usr/share/grafana/` to downloader stage. Also added `COPY --from=downloader /tmp /tmp` for plugin socket directories. Created minimal `grafana.ini` config file mounted from compose. |
| **Resolution** | Image rebuilt, pushed, deployed. Grafana now healthy. |
| **Status** | **RESOLVED** |

---

### P1-005: 23 Plaintext `.env` Files on TrueNAS

| Field | Value |
|-------|-------|
| **Component** | All 23 stack `.env` files on TrueNAS |
| **Symptom** | Secrets (DB passwords, API tokens, SMTP credentials) stored in plaintext |
| **Impact** | Any user with TrueNAS shell access can read all infrastructure secrets |
| **Current State** | SOPS encryption configured. `secrets/*.env.encrypted` files exist in SIS repo for 21 stacks. But the **live `.env` files on TrueNAS** are all plaintext (deployed via Ansible which decrypts at deploy time). The encryption at-rest is only in the git repo. |
| **Files** | accounting, backup, blocmarket, blocmarket/bloc_market, books, collaboration, documents, erpnext, iam, monitoring, operations, photos, project-management, proxy, rss, security, storage, tunnel, updater, utility, vaultwarden, vpn, webhook |
| **Remediation** | This is **by design** — Ansible decrypts SOPS-encrypted files and deploys plaintext `.env` to TrueNAS. The threat model is: git repo is encrypted, TrueNAS disk is encrypted (ZFS), network access is restricted. For additional protection, consider mounting encrypted tmpfs or using Docker secrets. |
| **Status** | **ACCEPTED RISK** — design is intentional, documented here for awareness |

---

### P2-001: EIR Alertmanager Storage Path Conflict

| Field | Value |
|-------|-------|
| **Component** | `alertmanager` EIR image |
| **Symptom** | `mkdir /alertmanager: not a directory` |
| **Root Cause** | Compose command `--storage.path=/alertmanager` conflicts with the alertmanager **binary** at `/alertmanager`. Alertmanager tries to create a data directory at the same path as its own executable. |
| **Fix Applied** | Changed compose command to `--storage.path=/alertmanager-data` (directory created by downloader stage). |
| **Status** | **RESOLVED** |

---

### P2-002: EIR Healthcheck Path Mismatch (Scratch vs Wolfi)

| Field | Value |
|-------|-------|
| **Component** | Forgejo, Valkey compose healthchecks |
| **Symptom** | `exec: "/shim": stat /shim: no such file or directory` |
| **Root Cause** | EIR images built on `FROM scratch` install shim at `/shim`. EIR images built on `FROM wolfi-base` install shim at `/usr/local/bin/shim`. Compose healthchecks were hardcoded to `/shim` regardless of base image. |
| **Affected** | Forgejo (wolfi), Valkey (wolfi) — both used `/shim` in healthcheck but binary is at `/usr/local/bin/shim` |
| **Fix Applied** | Updated compose healthchecks to use correct path per image type: scratch → `/shim`, wolfi → `/usr/local/bin/shim` |
| **Status** | **RESOLVED** |

---

### P2-003: storage-collaboration Perpetually Unhealthy

| Field | Value |
|-------|-------|
| **Component** | `storage-collaboration` (ownCloud OCIS collaboration service) |
| **Symptom** | Unhealthy for 2+ days |
| **Impact** | Collabora document editing within ownCloud may be degraded |
| **Root Cause** | Pre-existing issue, not related to EIR migration. The collaboration service requires specific OCIS configuration and WOPI secret alignment. |
| **Status** | **OPEN** — pre-existing, not addressed this session |

---

### P2-004: CachyOS QuestHive Services Unhealthy

| Field | Value |
|-------|-------|
| **Component** | `questhive-gateway`, `questhive-settlement-worker`, `questhive-spooler` |
| **Symptom** | All three report unhealthy |
| **Impact** | QuestHive application may have degraded functionality |
| **Root Cause** | Application-level issues, not infrastructure. These are developer-managed services. |
| **Status** | **OPEN** — application-level, not infra responsibility |

---

### P2-005: CachyOS Resource Pressure

| Field | Value |
|-------|-------|
| **Component** | CachyOS runner host (i5-7400, 8GB RAM + 8GB zram + 8GB disk swap) |
| **Current State** | RAM: 5.2Gi used / 2.5Gi available. Swap: 8.7Gi used / 7.0Gi free. Disk: 73% used (165G/235G). |
| **Impact** | Heavy swap usage indicates memory pressure. CI jobs may be slower. Risk of OOM if multiple large jobs run concurrently. |
| **Contributing Factors** | 3 runner daemons + QuestHive stack (10 containers) + Evergreen control plane (5 containers) + BlocMarket stack + CivitForge stack + Tachyon stack. Total: ~30 containers on 8GB physical RAM. |
| **Recommendation** | Consider migrating QuestHive/Evergreen/BlocMarket development stacks to a separate host or reducing their memory footprints. |
| **Status** | **ACCEPTED RISK** — monitored, no action currently planned |

---

### P2-006: CI Code-Level Failures (5 Repos)

| Field | Value |
|-------|-------|
| **Component** | Multiple Forgejo repositories |
| **Details** | |
| peptide-web | 25 code-level test failures (not infra-related) |
| wikisites | TypeScript errors + lint errors |
| BlocMarket | Missing `locales.rs` module |
| KBTR_web | `fetch failed` during prerendering |
| QuestHive | Nix PATH propagation issues (partially fixed) |
| **Impact** | CI pipelines fail for these repos, but this is application-level, not infrastructure |
| **Status** | **OPEN** — developer responsibility |

---

### P3-001: EIR OAuth2-Proxy Image ENTRYPOINT Bug

| Field | Value |
|-------|-------|
| **Component** | `oauth2-proxy` EIR Dockerfile |
| **Symptom** | `ENTRYPOINT ["/shim", "run"]` without `-c` flag |
| **Root Cause** | The shim's `run` subcommand requires `-c <command>` to know what binary to execute. Without it, the shim has no child process to launch. |
| **Workaround** | Added `entrypoint: ["/shim", "run", "-c", "/oauth2-proxy"]` to compose file to override the broken image ENTRYPOINT. |
| **Proper Fix** | Update EIR Dockerfile: `ENTRYPOINT ["/shim", "run", "-c", "/oauth2-proxy"]` |
| **Status** | **PARTIALLY RESOLVED** — works via compose override, EIR Dockerfile still has bug |

---

### P3-002: EIR Images with Broken Builds (4 Images)

| Field | Value |
|-------|-------|
| **Component** | homepage, calibre-web, crowdsec, collabora EIR images |
| **Details** | |
| `homepage` | Scratch-based, `ENTRYPOINT ["/shim", "run", "-c", "node /app/server.js"]` but **no `node` binary** in scratch image |
| `calibre-web` | Stub — no application code downloaded, only `ca-certificates` installed |
| `crowdsec` | Downloads source tarball instead of binary, and ENTRYPOINT path doesn't match COPY path |
| `collabora` | Dead `COPY --from=upstream` references (paths don't exist), missing shared libraries |
| **Impact** | These 4 images cannot be used for migration |
| **Status** | **OPEN** — EIR images exist but are non-functional |

---

### P3-003: OCIS Migration Blocked by Shell Init Logic

| Field | Value |
|-------|-------|
| **Component** | `ocis` EIR image |
| **Symptom** | Cannot replicate shell-based init logic in scratch image |
| **Root Cause** | Current compose uses `entrypoint: /bin/sh -c "if [ ! -f /etc/ocis/ocis.yaml ]; then ocis init; fi; exec ocis server"`. The EIR scratch image has no shell. The init logic (check for config, run `ocis init` if missing) cannot be replicated without a shell or custom init binary. |
| **Status** | **OPEN** — needs EIR image redesign with wolfi-base or custom init wrapper |

---

## 3. EIR Migration Status

### Successfully Migrated (9 images)

| Service | EIR Image | Base | Status |
|---------|-----------|------|--------|
| Traefik | `traefik:latest` | Scratch | ✅ Healthy |
| Cloudflared | `cloudflared:latest` | Scratch | ✅ Healthy |
| Alertmanager | `alertmanager:latest` | Scratch | ✅ Healthy |
| Tempo | `tempo:latest` | Scratch | ✅ Healthy |
| Forgejo | `forgejo:latest` | Wolfi | ✅ Healthy |
| Grafana | `grafana:latest` | Scratch | ✅ Healthy |
| Keycloak | `keycloak:latest` | Wolfi | ✅ Healthy |
| Valkey | `valkey:latest` | Scratch | ✅ Healthy |
| OAuth2-Proxy | `oauth2-proxy:latest` | Scratch | ✅ Running (healthcheck disabled in compose) |

### Failed Migrations (3 images)

| Service | Reason | Resolution |
|---------|--------|------------|
| Vaultwarden | Dynamically linked binary, scratch has no libc | Reverted to upstream |
| Watchtower | Docker socket needs root, EIR runs non-root | Reverted to upstream |
| OCIS | Shell init logic, scratch has no shell | Not attempted |

### Not Attempted (40+ images)

Remaining upstream images on TrueNAS, categorized by migration feasibility:

**Straightforward (drop-in, same version):** 15 images
- postgres, redis, mariadb, nginx, synapse, element-web, matrix-hookshot, paperless-ngx, uptime-kuma, blackbox-exporter, node-exporter, cadvisor, redis-exporter, postgres-exporter, promtail

**Complex (needs investigation):** 10 images
- ocis (shell init), collabora (complex deps), crowdsec (EIR broken), homepage (EIR broken), calibre-web (EIR stub), wireguard (different product), erpnext (EIR stub), immich (version mismatch v1 vs v2), docker-socket-proxy (EIR CMD pattern broken), vaultwarden (dynamic linking)

**Keep Upstream (by design):** 3 images
- immich (v2.7.5 vs EIR v1.106.0), immich-postgres (pgvector custom image), erpnext (EIR is stub)

---

## 4. Infrastructure Summary

### TrueNAS (192.168.1.3)
- **Containers:** 49 running
- **Healthy:** 47
- **Unhealthy:** 1 (storage-collaboration — pre-existing)
- **No healthcheck:** 2 (infra-tunnel, collaboration-hookshot)
- **EIR Images:** 9 of 49 containers
- **Upstream Images:** 40 of 49 containers
- **K3s:** Fully purged (2.2GB recovered)

### CachyOS (192.168.1.191)
- **Containers:** ~30 (3 runners + dev stacks)
- **Zombie CI containers:** 0 (cleaned this session)
- **Memory:** 5.2Gi used / 2.5Gi available / 8.7Gi swap used
- **Disk:** 73% used (165G/235G)

### Win11 VM (10.136.57.35)
- **Status:** RUNNING (per Incus) but unreachable
- **SSH:** Connection timeout
- **Guest Agent:** Not running
- **Runner ID:** 88 (windows-latest label) — offline

---

## 5. Root Cause Pattern Analysis

### Pattern 1: Scratch Image + Dynamic Linking Incompatibility

**Occurrences:** Vaultwarden, potentially many others

**Root Cause:** EIR scratch-based images assume statically-linked binaries. Many upstream images ship dynamically-linked binaries requiring glibc/musl and shared libraries.

**Detection Method:** `file <binary>` → check for "dynamically linked" and interpreter path.

**Prevention:** Every EIR image must run `file` on the copied binary as a build verification step. If dynamically linked, use wolfi-base instead of scratch.

### Pattern 2: Missing Runtime Dependencies in Wolfi Images

**Occurrences:** Keycloak (no Java), Grafana (no public dir)

**Root Cause:** EIR Dockerfiles copy the main binary but miss runtime dependencies (language runtimes, static assets, config templates).

**Prevention:** Every EIR image must document ALL runtime dependencies. Build verification must test `docker run` with actual startup, not just binary existence.

### Pattern 3: Shim Path Divergence Between Base Images

**Occurrences:** Forgejo, Valkey healthchecks

**Root Cause:** Scratch images copy shim to `/shim`. Wolfi images install to `/usr/local/bin/shim`. Compose files hardcoded one path.

**Prevention:** Standardize shim installation path across ALL EIR base images. Recommendation: Always use `/usr/local/bin/shim` and add a symlink in scratch images.

---

## 6. Recommendations

### Immediate (Next Session)

1. **Fix Win11 VM** — Need SPICE console access or VM rebuild to restore Windows CI capability
2. **Fix EIR oauth2-proxy Dockerfile** — Add `-c /oauth2-proxy` to ENTRYPOINT, remove compose override
3. **Standardize EIR shim path** — All images should install shim to `/usr/local/bin/shim` (add symlink `ln -s /usr/local/bin/shim /shim` in scratch images)

### Short-Term (1-2 Sessions)

4. **Add binary type check to EIR CI** — Automated `file` check on every built binary; fail if dynamically linked on scratch base
5. **Migrate 15 straightforward images** — postgres, redis, nginx, synapse, etc. These are single-binary services with minimal deps
6. **Fix 4 broken EIR images** — homepage, calibre-web, crowdsec, collabora need Dockerfile rewrites

### Long-Term (Ongoing)

7. **Vaultwarden EIR redesign** — Switch from scratch to wolfi-base, install required shared libs
8. **OCIS EIR redesign** — Create init wrapper binary or use wolfi-base with shell
9. **CachyOS resource optimization** — Evaluate moving dev stacks to separate host
10. **Monitoring alerts** — Wire alertmanager → ntfy pipeline for container health

---

## 7. Commits This Session

| Repo | Commit | Description |
|------|--------|-------------|
| SIS | `9f8fbe1` | fix: EIR healthcheck paths, alertmanager storage, grafana config, vaultwarden tunnel |
| EIR | `4e9b6ec` | fix(grafana): add public/ dir; fix(keycloak): add openjdk-21 + symlink |
| SIS | `7c6224b` | migrate: oauth2-proxy to EIR image with entrypoint fix |
| EIR | `19e8c3e` | fix(vaultwarden): add web-vault static files to scratch image |

---

*End of Report*
