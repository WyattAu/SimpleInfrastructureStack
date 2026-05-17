# Evergreen Image Registry -- SimpleInfrastructureStack Compatibility Audit

**Date:** 2026-05-17
**Scope:** 49 unique SIS images vs 998 Evergreen images
**Method:** Static analysis of Evergreen Dockerfiles and manifest.toml files against SIS compose configurations. Pull attempts to ghcr.io/wyattau/evergreenimageregistry failed (UNAUTHORIZED/DENIED) -- packages may be private or not yet published. Analysis performed on source only.

---

## Executive Summary

| Verdict | Count | Percentage |
|---------|-------|------------|
| READY (drop-in) | 2 | 5% |
| NEEDS_ADAPTATION | 13 | 33% |
| BLOCKED | 20 | 51% |
| N/A (not used by SIS) | 2 | 5% |
| NO MATCH in Evergreen | 12 | -- |

37 of 49 SIS images (75%) have an Evergreen catalog counterpart. Of those, only 2 are ready for deployment without significant changes. 20 are fundamentally blocked.

---

## Systemic Issues

### 1. Skeleton/Placeholder Images (12 images)

The following Evergreen images contain only base OS packages with **no actual application binary**. Their Dockerfiles install `ca-certificates` or language runtimes but never download or copy the upstream application:

| Image | What is Missing |
|-------|----------------|
| uptime-kuma | No Uptime Kuma source code; only Node.js runtime installed |
| freshrss | No FreshRSS source; no web server (nginx/apache); no php-pgsql extension |
| mariadb | No MariaDB server binary; no init scripts; no mysql_install_db |
| collabora-online-code | No loolwsd binary; only curl and gnupg installed |
| rabbitmq | No Erlang runtime; no RabbitMQ server; no rabbitmqctl |
| akaunting | No Laravel application code; no nginx config; php-fpm alone cannot serve HTTP |
| calibre-web | No Python packages; no Calibre-Web source; entrypoint starts bare Python shell |
| redis | Redis binary noted as "not available in wolfi; uses pre-compiled binary" -- likely non-functional |
| keycloak | No JRE in wolfi base; Keycloak tar.gz bundle includes JRE but Dockerfile does not extract it properly |
| crowdsec | Bare binary only; no cscli, no initialization logic, no LAPI setup |
| homepage | Copies `/app` from upstream but misses Node.js runtime and system dependencies outside `/app` |
| cloudflare-warrior | Binary download exists but URL and version may be incorrect for current cloudflared |

**Impact:** These images cannot run the intended application. They appear to be scaffolding for future development, not production-ready replacements.

### 2. glibc vs musl C Extension Mismatch (3 images)

Python applications built on Debian (glibc) and copied into wolfi (musl libc) will fail at runtime when loading C extensions:

| Image | Failing C Extensions |
|-------|---------------------|
| synapse | psycopg2, Pillow, crypto modules |
| paperless-ngx | psycopg2, Pillow (OCR), python-Levenshtein |
| taiga-backend | psycopg2, django dependencies |

**Root Cause:** Evergreen Dockerfiles use multi-stage builds where the Python venv is created in a Debian builder stage, then copied to a wolfi final stage. Python C extensions compiled against glibc cannot load against musl.

**Fix Required:** Build Python extensions in the wolfi/musl stage directly, or use `manylinux` wheels that include glibc.

### 3. UID 65532:65532 vs SIS UIDs

All Evergreen images run as `USER 65532:65532` (nonroot). SIS uses specific UIDs:

| Service | SIS UID | Conflict |
|---------|---------|----------|
| grafana | 472 | Init container chowns to 472; Evergreen runs as 65532 |
| postgres (all instances) | 999 (PG 17) or 70 (PG 18) | Data dirs owned by wrong UID |
| forgejo | 1001 (PUID) | Upstream entrypoint uses USER_UID env; Evergreen ignores it |
| synapse | 1001 (PUID) | Data dir ownership mismatch |
| keycloak | root (no PUID) | Evergreen forces 65532 |
| all others | 1001 (PUID) or root | Volumes need re-chowning |

**Impact:** Volume mounts owned by the wrong UID cause permission denied errors. Every SIS service using Evergreen images would need init container changes to chown to 65532.

### 4. No Shell in Scratch Images (15 images)

SIS healthchecks universally use `CMD-SHELL` format, which requires `/bin/sh`. These 15 Evergreen images are `FROM scratch` with no shell:

alertmanager, node-exporter, oauth2-proxy, promtail, cadvisor, crowdsec, vaultwarden, restic, postgres-exporter, redis-exporter, blackbox-exporter, victoriametrics, homepage, nextcloud-ocis, cloudflare-warrior

**Impact:** All SIS healthchecks for these services would fail. Must convert to `CMD` format using the binary directly, or remove healthchecks and rely on docker-compose healthcheck overrides.

### 5. No Init Systems for Databases (4 images)

Database containers require initialization logic (initdb, user creation, locale setup) that the bare Evergreen binaries do not include:

| Image | Missing |
|-------|---------|
| postgres | No initdb, no chown, no locale, no gosu/user-switching |
| mariadb | No binary at all; no mysql_install_db |
| redis | Binary may not be available; no data dir setup |
| rabbitmq | No Erlang runtime; no rabbitmqctl |

**Impact:** These cannot be drop-in replacements. SIS relies on upstream entrypoints for database initialization.

---

## Per-Image Detailed Analysis

### READY -- Drop-in Compatible (2)

#### traefik
- **Base:** scratch | **Ports:** 80, 443, 8080 | **USER:** 65532
- **SIS adaptation:** Pre-chown letsencrypt dir to 65532. Ensure `net.ipv4.ip_unprivileged_port_start=0` on host for non-root binding to ports 80/443. Add tmpfs for writable dirs if using read-only rootfs.
- **Risk:** Low. Traefik upstream supports non-root operation.

#### vaultwarden
- **Base:** scratch | **Ports:** 8080 | **USER:** 65532
- **SIS adaptation:** Change Traefik service port label from 80 to 8080. Pre-chown `/data` volume to 65532. Remove or replace `CMD-SHELL curl` healthcheck (no shell in scratch).
- **Risk:** Low. Binary is identical to upstream.

### NEEDS_ADAPTATION -- Minor Changes Required (13)

#### grafana
- **Base:** wolfi | **Ports:** 3000 | **USER:** 65532
- **Changes:** Change init container chown from 472 to 65532. Verify homepath `/opt/grafana` vs upstream `/usr/share/grafana`. Add tmpfs mounts for writable dirs.
- **Risk:** Medium. Config path difference may require testing.

#### node-exporter
- **Base:** scratch | **Ports:** 9100 | **USER:** 65532
- **Changes:** Convert healthcheck from `CMD-SHELL wget ...` to `CMD ["wget", "-qO-", "http://127.0.0.1:9100/metrics"]` or remove.
- **Risk:** Low. Binary is identical.

#### oauth2-proxy
- **Base:** scratch | **Ports:** 4180 | **USER:** 65532
- **Changes:** Verify env var handling works with non-root user. No other changes needed.
- **Risk:** Low.

#### promtail
- **Base:** scratch | **Ports:** 9080 | **USER:** 65532
- **Changes:** Verify config file readability by 65532. No other changes.
- **Risk:** Low.

#### cadvisor
- **Base:** scratch | **Ports:** 8080 | **USER:** 65532
- **Changes:** Convert healthcheck to CMD format. Dockerfile hardcodes `linux-amd64` download URL -- will fail on arm64.
- **Risk:** Medium. Multi-arch bug.

#### forgejo
- **Base:** wolfi | **Ports:** 3000, 22 | **USER:** 65532
- **Changes:** Pre-chown data dir to 65532. Fix SSH port mapping (Evergreen exposes 22, SIS uses 2522 in container). Remove unused caps (CHOWN, DAC_OVERRIDE, etc.). Remove USER_UID/USER_GID env vars (ignored). Convert healthcheck to CMD format.
- **Risk:** Medium. SSH port change requires Forgejo config update.

#### element-web
- **Base:** wolfi (busybox httpd) | **Ports:** 80 | **USER:** 65532
- **Changes:** Verify config.json mount at `/app/config.json` works with busybox httpd serving `/app`.
- **Risk:** Low. Static files only.

#### valkey
- **Base:** wolfi | **Ports:** 6379 | **USER:** 65532
- **Changes:** Remove unnecessary caps. Verify valkey-cli binary exists in wolfi image for healthcheck.
- **Risk:** Low. Ephemeral data (Immich cache).

#### cloudflare-warrior (cloudflared)
- **Base:** scratch | **Ports:** 7844 | **USER:** 65532
- **Changes:** Verify config file readability by 65532.
- **Risk:** Low. All config via command args.

#### postgres-exporter
- **Base:** scratch | **Ports:** 9187 | **USER:** 65532
- **Changes:** Fix init container pgpass chown UID from 65534 to 65532. Convert healthcheck to CMD format.
- **Risk:** Low.

#### redis-exporter
- **Base:** scratch | **Ports:** 9121 | **USER:** 65532
- **Changes:** None required. Pure env-based config.
- **Risk:** Low.

#### victoriametrics
- **Base:** scratch | **Ports:** 8428 | **USER:** 65532
- **Changes:** Pre-chown data dir to 65532. Convert healthcheck to CMD format. Verify download URL is for single-node (not cluster tarball).
- **Risk:** Medium. Download URL may be wrong.

#### prometheus-blackbox-exporter
- **Base:** scratch | **Ports:** 9115 | **USER:** 65532
- **Changes:** Fix config file mount path from `/etc/blackbox_exporter/config.yml` to `/etc/prometheus-blackbox-exporter/blackbox.yml`. Convert healthcheck to CMD format.
- **Risk:** Low. Path change only.

### BLOCKED -- Fundamental Incompatibility (20)

#### alertmanager
- **Blocker:** SIS uses custom `/entrypoint.sh` (shell script) for config templating. Scratch image has no shell.
- **Workaround:** Rewrite entrypoint as a static Go binary, or use a sidecar for templating.

#### postgres (all 6 instances)
- **Blocker:** No initdb, no user creation, no locale setup, no gosu. Bare binary only.
- **Workaround:** Use init containers to run initdb, or contribute init scripts to Evergreen.

#### redis
- **Blocker:** Redis binary may not be available in wolfi. No data dir setup.
- **Workaround:** Use valkey (which has a working wolfi package) as a Redis-compatible replacement.

#### keycloak
- **Blocker:** No JRE in wolfi base image. Keycloak cannot start without Java.
- **Workaround:** Add JRE installation to the Evergreen Dockerfile, or use a distroless base with JRE.

#### uptime-kuma
- **Blocker:** No application code. Only Node.js runtime installed.
- **Workaround:** Add Uptime Kuma source download to the Dockerfile.

#### crowdsec
- **Blocker:** No initialization logic, no cscli binary, no config management.
- **Workaround:** Contribute full CrowdSec packaging to Evergreen (complex).

#### freshrss
- **Blocker:** No application code, no web server, no php-pgsql extension.
- **Workaround:** Add FreshRSS source, nginx config, and php-pgsql to the Dockerfile.

#### synapse
- **Blocker:** Python C extensions (psycopg2) built on glibc won't load on wolfi musl. No `/start.py` for config generation.
- **Workaround:** Build Python extensions in wolfi stage directly, or use Debian final stage.

#### paperless-ngx
- **Blocker:** Same glibc/musl mismatch. No USERMAP_UID support.
- **Workaround:** Build Python extensions in wolfi stage, or use Debian final stage.

#### mariadb
- **Blocker:** No binary installed. Skeleton Dockerfile only.
- **Workaround:** Contribute full MariaDB packaging to Evergreen.

#### restic
- **Blocker:** SIS overrides entrypoint to `tail -f /dev/null` (requires shell). Scratch has no shell.
- **Workaround:** Use a distroless base with shell for the keepalive entrypoint, or rewrite as a static binary.

#### nextcloud-ocis
- **Blocker:** SIS entrypoint requires `/bin/sh` for first-run `ocis init`. Scratch has no shell.
- **Workaround:** Move init logic to a separate init container, run OCIS binary directly.

#### homepage
- **Blocker:** Copies `/app` from upstream but misses Node.js runtime at `/usr/local/bin/node` and system deps outside `/app`.
- **Workaround:** Copy the full upstream filesystem, not just `/app`.

#### collabora-online-code
- **Blocker:** No loolwsd binary. Skeleton Dockerfile only.
- **Workaround:** Contribute full Collabora packaging to Evergreen (very complex).

#### rabbitmq
- **Blocker:** No Erlang runtime, no RabbitMQ server.
- **Workaround:** Contribute full RabbitMQ packaging to Evergreen.

#### taiga-backend
- **Blocker:** glibc/musl mismatch. Path structure differs from upstream. Custom entrypoint expects paths that don't exist.
- **Workaround:** Build in Debian stage, or restructure paths.

#### taiga-front
- **Blocker:** No config generation entrypoint. Frontend needs runtime config injection (API URLs).
- **Workaround:** Add config generation logic to the Evergreen Dockerfile.

#### akaunting
- **Blocker:** No application code. No web server config.
- **Workaround:** Add Akaunting source, nginx config to the Dockerfile.

#### calibre-web
- **Blocker:** No application code. Only ca-certificates installed.
- **Workaround:** Add Calibre-Web source and dependencies to the Dockerfile.

#### wireguard
- **Blocker:** Completely different implementation (userspace wireguard-go vs kernel wg-quick). No config management. No privilege escalation (ALL caps dropped).
- **Workaround:** Not feasible without adding NET_ADMIN cap back and writing full config management.

### N/A -- Not Used by SIS (2)

#### prometheus
- SIS uses VictoriaMetrics (Prometheus-compatible), not Prometheus directly.

#### nginx
- SIS uses Traefik as reverse proxy. Only uses Chainguard nginx for taiga-gateway (already hardened).

### NO MATCH in Evergreen (12)

These SIS images have no counterpart in the 998-image Evergreen catalog:

| SIS Image | Notes |
|-----------|-------|
| prom/mysqld-exporter | Evergreen has `mysql-exporter` but not `mysqld-exporter` (different binary) |
| matrix-hookshot | No Matrix hookshot bridge variant |
| vmalert | vm-agent exists but is a different VictoriaMetrics component |
| victoria-logs | No VictoriaLogs in catalog |
| tempo (Grafana) | No Grafana Tempo in catalog |
| taiga-events | No events microservice variant |
| taiga-protected | No protected API variant |
| cloudflare-ddns | cloudflare-warrior is cloudflared, not a DDNS updater |
| docker-socket-proxy | Not in catalog |
| watchtower | Not in catalog |
| busybox | Not in catalog (used as init containers) |
| zfs-exporter | Not in catalog |

---

## Infrastructure Problem: ghcr.io Access

Pull attempts to `ghcr.io/wyattau/evergreenimageregistry/*` returned `UNAUTHORIZED`/`DENIED`. The packages are either:

1. Published to a private org (requires GitHub PAT to pull)
2. Linked to a private container registry
3. Not yet published (the build workflow is `workflow_dispatch` only and marked DEPRECATED)

The newer build workflows (`build-on-push.yml`, `build-nightly.yml`, `build-on-demand.yml`) referenced in the deprecated build.yml do not appear to exist in the repository. No published packages were found at `github.com/WyattAu/packages`.

**Recommendation:** Verify package publishing is configured and working. Consider making packages public if they are intended for external use.

---

## Recommendations

### Short Term (images READY or NEEDS_ADAPTATION)

1. **traefik and vaultwarden** can be adopted immediately with minor compose changes.
2. **node-exporter, oauth2-proxy, promtail, postgres-exporter, redis-exporter** can be adopted after healthcheck conversion from CMD-SHELL to CMD format.
3. **victoriametrics, cadvisor** need healthcheck fixes plus data dir ownership changes.

### Medium Term (fixable BLOCKED images)

4. **alertmanager** -- rewrite entrypoint.sh as a binary or use env-based config (no templating needed if config is static).
5. **redis** -- replace with valkey (Evergreen valkey image works).
6. **blackbox-exporter** -- fix config mount path.
7. **cloudflare-warrior** -- verify download URL and version.

### Long Term (require Evergreen contributions)

8. **postgres** -- contribute init scripts (initdb, user creation, locale) to the Evergreen postgres Dockerfile.
9. **keycloak** -- add JRE to the wolfi base.
10. **Python apps** (synapse, paperless-ngx, taiga-backend) -- build C extensions in wolfi stage or switch to Debian final stage.
11. **Skeleton images** (uptime-kuma, freshrss, mariadb, collabora, rabbitmq, akaunting, calibre-web) -- contribute full application packaging.
12. **homepage** -- copy full upstream filesystem, not just `/app`.

### Not Recommended for Migration

- **wireguard** -- fundamentally different implementation. The LinuxServer.io image provides kernel WireGuard with full config management; Evergreen provides only the userspace binary.
- **crowdsec** -- requires extensive initialization that is tightly coupled to the upstream entrypoint.
- **nextcloud-ocis** -- requires shell-based first-run init that is incompatible with scratch.
- **restic** -- SIS uses `tail -f /dev/null` as keepalive entrypoint; would need architecture change.
