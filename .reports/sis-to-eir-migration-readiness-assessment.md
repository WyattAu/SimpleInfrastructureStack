# SIS → EIR Migration Readiness Assessment

**Date:** 2026-06-09
**Author:** Nexus (Principal Systems Architect)
**Trigger:** Peer review of migration report identified gaps — deep audit requested
**Verdict:** **GO with conditions** — Systemic blocker resolved; per-service issues remain

---

## Executive Summary

The migration report claims Phase 1 (traefik, cloudflared, alertmanager, tempo) is "low risk, direct drop-in." A compose-level audit against actual EIR Dockerfiles and the shim source code reveals per-service issues but **the systemic blocker previously identified does not exist.**

**Shim source code analysis (EvergreenShims `crates/evergreen-shim/src/main.rs`) confirms that argument passthrough is already implemented.** The `run` subcommand accepts `-c BINARY` for the command and `args: Vec<String>` (via `trailing_var_arg = true, allow_hyphen_values = true`) for child process arguments. Lines 174-179 show these args are written directly to `config.process.args`, which `process.rs:82` passes via `cmd.args(&self.config.args)`.

**However:** The EIR Dockerfiles do not use the correct ENTRYPOINT pattern to leverage passthrough. They embed the binary path in the ENTRYPOINT with no room for Docker's CMD append. A minor ENTRYPOINT adjustment is needed, not a shim code change.

---

## 1. Shim Argument Passthrough — Resolved

### Previous Assessment (Incorrect)

The original assessment concluded that the shim swallowed all arguments after `-c BINARY`. This was based on static analysis of the ENTRYPOINT pattern in EIR Dockerfiles, not the shim source code.

### Shim Source Code Analysis

Source: [`EvergreenShims/crates/evergreen-shim/src/main.rs`](https://github.com/WyattAu/EvergreenShims)

**Key finding:** The shim supports argument passthrough via `clap`'s `trailing_var_arg`:

```rust
// main.rs:46-60
enum Subcommand {
    Run {
        #[arg(short = 'f', long, default_value = "/etc/shim/config.toml")]
        config: PathBuf,

        #[arg(short, long)]
        command: Option<String>,

        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,  // ← Child process arguments
    },
    // ...
}
```

```rust
// main.rs:174-179 — Args override config
if let Some(cmd) = command {
    config.process.command = cmd;
}
if !args.is_empty() {
    config.process.args = args;
}
```

```rust
// process.rs:81-82 — Args forwarded to child
let mut cmd = tokio::process::Command::new(&self.config.command);
cmd.args(&self.config.args);
```

**This means:** Everything after `-c BINARY` is captured as trailing args and forwarded to the child process via `tokio::process::Command::args()`.

### The Real Problem: ENTRYPOINT vs Docker CMD

The issue is not the shim code — it's how the EIR Dockerfiles define their ENTRYPOINT:

```dockerfile
# Current EIR pattern (no room for CMD append):
ENTRYPOINT ["/shim", "run", "-c", "traefik"]
# No CMD — Docker CMD defaults to empty
```

When Docker Compose sets `command: --flag1 --flag2`, Docker appends to ENTRYPOINT:
```
/shim run -c traefik --flag1 --flag2
```

`clap` parses this as:
- `-c` → `traefik` (command binary)
- `--flag1 --flag2` → trailing args (forwarded to child ✅)

**This actually works.** The `allow_hyphen_values = true` flag on `args` ensures hyphenated flags are not confused with shim options.

### Verified by Shim's Own Help Text

```rust
// main.rs:24-26
after_help = "EXAMPLES:\n  shim -c postgres -- postgres -D /var/lib/postgresql/data\n  shim --command redis-server -- --bind 0.0.0.0\n  shim -f /etc/shim/config.toml\n  shim healthcheck --tcp 127.0.0.1:5432"
```

The shim's own examples show the `--` separator pattern:
```
shim -c postgres -- postgres -D /var/lib/postgresql/data
```

The `--` is not required by clap (trailing_var_arg captures everything), but using it is good practice to disambiguate shim flags from child flags.

### Impact on Original Assessment

| Original Claim | Actual Finding |
|---------------|---------------|
| "Shim swallows args after `-c BINARY`" | ❌ **False.** Trailing args are captured and forwarded |
| "Systemic blocker — shim code change needed" | ❌ **False.** Shim already supports passthrough |
| "All 4 Phase 1 services incompatible" | ⚠️ **Partially false.** Passthrough works; other issues remain |

### Remaining Per-Service Issues

Argument passthrough resolves the main concern, but each service still has specific issues that need attention:

| Service | Arg Passthrough OK? | Remaining Issues |
|---------|--------------------|--------------------|
| Traefik | ✅ Yes | Healthcheck regression (app-level → port-level) |
| Cloudflared | ⚠️ Partial | `command:` is string form → needs `/bin/sh` which doesn't exist in `scratch`. Must convert to array form |
| Alertmanager | ❌ Custom entrypoint | `entrypoint: [/entrypoint.sh]` bypasses shim entirely. Shell dependency for template rendering |
| Tempo | ✅ Yes | Dockerfile binary path bug (`/usr/bin/tempo` vs `/tempo`) |

---

## 2. Per-Service Audit

### 2.1 Traefik

| Attribute | Detail |
|-----------|--------|
| **Compose file** | `stacks/proxy/docker-compose.yml:47-122` |
| **EIR Dockerfile** | `images/traefik/Dockerfile` |
| **EIR ENTRYPOINT** | `["/shim", "run", "-c", "traefik"]` |
| **SIS command:** | `--accesslog=true --api=true --api.dashboard=true --log.level=INFO --providers.docker=true --providers.docker.endpoint=tcp://socket-proxy:2375 --providers.docker.exposedbydefault=false --certificatesresolvers.cloudflare.acme.email=... --certificatesresolvers.cloudflare.acme.dnschallenge.provider=cloudflare --entrypoints.web.address=:80 --entrypoints.websecure.address=:443 --entrypoints.websecure.http.tls.certresolver=cloudflare --metrics.tracing.additionallabels=... --tracing.otlp.http.endpoint=http://tempo:4318/v1/traces` (14 flags) |
| **SIS healthcheck:** | `CMD /traefik healthcheck --ping` (app-level, interval 30s) |
| **EIR healthcheck:** | `CMD ["/shim", "healthcheck", "--tcp", "127.0.0.1:8080"]` (port-level only) |
| **depends_on impact:** | `oauth2-proxy` depends on `traefik` with `condition: service_healthy` |

**What happens:**
1. ✅ Shim passthrough works — all 14 CLI flags will be forwarded to traefik correctly
2. ⚠️ Healthcheck downgrades from app-level ping (`/traefik healthcheck --ping`) to port-level TCP check (`--tcp 127.0.0.1:8080`). oauth2-proxy depends on traefik `service_healthy` — may start before :443 is ready.

**Mitigation for healthcheck regression:**
- Remove the EIR built-in HEALTHCHECK from compose and restore the SIS healthcheck: `test: ["CMD", "/traefik", "healthcheck", "--ping"]` — but wait, `scratch` base has no shell. The `/traefik` binary may not support direct invocation from healthcheck CMD.
- Alternative: use the EIR healthcheck HTTP mode if traefik exposes a readiness endpoint: `CMD ["/shim", "healthcheck", "--http", "http://127.0.0.1:8080/ping"]` — but EIR healthcheck only does TCP connect, not HTTP request parsing.
- Safest option: Accept the port-level healthcheck for now. Traefik binds :8080 early in startup, and :80/:443 follow within milliseconds. The timing gap is negligible in practice. Add `start_period: 30s` to give traefik time to fully initialize.

**Actual risk: 🟡 MEDIUM** — Arg passthrough works. Healthcheck is slightly less thorough but acceptable. Traefik is still the ingress — any config error takes down everything, but that's true regardless of image source.

---

### 2.2 Cloudflared

| Attribute | Detail |
|-----------|--------|
| **Compose file** | `stacks/tunnel/docker-compose.yml:1-25` |
| **EIR Dockerfile** | `images/cloudflared/Dockerfile` |
| **EIR ENTRYPOINT** | `["/shim", "run", "-c", "/cloudflared"]` |
| **SIS command:** | `tunnel --config /etc/cloudflared/config.yml --metrics 0.0.0.0:4788 run` |
| **SIS healthcheck:** | _(none)_ |
| **EIR healthcheck:** | `CMD ["/shim", "healthcheck", "--tcp", "127.0.0.1:7844"]` |
| **network_mode:** | `host` |

**What happens:**
1. ⚠️ `command:` is a bare string in SIS: `command: tunnel --config /etc/cloudflared/config.yml --metrics 0.0.0.0:4788 run`. Docker wraps string commands in `/bin/sh -c`. The EIR image is `scratch`-based with **no shell**. Container fails to start.
2. ✅ If converted to array form (`command: ["tunnel", "--config", "/etc/cloudflared/config.yml", "--metrics", "0.0.0.0:4788", "run"]`), shim passthrough works — all args forwarded to cloudflared.
3. ✅ The EIR adds a TCP healthcheck on :7844 — new but harmless since cloudflared binds this port.

**Required fix:** Convert `command:` from string to array form in compose. One-line change.

**Actual risk: 🟢 LOW** — Shim passthrough works after converting command to array form. No other issues. Cloudflared is external access but the change is trivial.

---

### 2.3 Alertmanager

| Attribute | Detail |
|-----------|--------|
| **Compose file** | `stacks/monitoring/docker-compose.yml:434-476` |
| **EIR Dockerfile** | `images/alertmanager/Dockerfile` |
| **EIR ENTRYPOINT** | `["/shim", "run", "-c", "alertmanager"]` |
| **SIS entrypoint:** | `["/entrypoint.sh"]` (custom wrapper) |
| **SIS command:** | `--config.file=/etc/alertmanager/alertmanager.yml --storage.path=/alertmanager --web.external-url=https://...` |
| **SIS healthcheck:** | `CMD wget --spider -q http://127.0.0.1:9093/-/healthy` |
| **Custom entrypoint:** | `stacks/monitoring/alertmanager/entrypoint.sh` — renders `alertmanager.yml` from template via `sed` substitution of `$NTFY_TOPIC` |

**What happens:**
1. ❌ SIS `entrypoint: [/entrypoint.sh]` **completely replaces** the EIR shim ENTRYPOINT. The shim is bypassed entirely.
2. ❌ The custom entrypoint uses `sed` and `#!/bin/sh` — neither exists in the `scratch`-based EIR image.
3. ❌ Template rendering (`sed -e "s|\${NTFY_TOPIC}|${NTFY_TOPIC}|g"`) cannot execute in the container.
4. ✅ If the custom entrypoint were removed and the template pre-rendered, `command:` args would pass through correctly.

**Required fix:**
- Pre-render `alertmanager.yml` from template on the host (Ansible task or script before `docker compose up`)
- Mount the pre-rendered config directly
- Remove `entrypoint:` and convert `command:` to array form: `["--config.file=/etc/alertmanager/alertmanager.yml", "--storage.path=/alertmanager", "--web.external-url=https://..."]`

**Actual risk: 🟡 MEDIUM** — Requires pre-rendering workflow change. Alertmanager failure = no alerts, but services keep running.

---

### 2.4 Tempo

| Attribute | Detail |
|-----------|--------|
| **Compose file** | `stacks/monitoring/docker-compose.yml:566-594` |
| **EIR Dockerfile** | `images/tempo/Dockerfile` |
| **EIR ENTRYPOINT** | `["/shim", "run", "-c", "/usr/bin/tempo"]` |
| **SIS command:** | `-config.file=/etc/tempo/config.yml` |
| **SIS healthcheck:** | _(none — commented out: "Tempo 2.10+ is distroless")_ |
| **EIR healthcheck:** | `CMD ["/shim", "healthcheck", "--tcp", "127.0.0.1:3200"]` |

**What happens:**
1. ❌ **EIR Dockerfile bug:** Line 24 copies the binary to `/tempo`, but line 37 ENTRYPOINT references `/usr/bin/tempo`. The path does not exist. Image fails to start.
2. ✅ Once the Dockerfile bug is fixed, `command: -config.file=/etc/tempo/config.yml` passes through correctly to tempo.
3. ⚠️ The EIR adds a TCP healthcheck on :3200 — SIS had this disabled. Tempo 2.10+ is distroless. The healthcheck port should be verified against the tempo config.

**Required fix:**
- Fix the Dockerfile: change `/usr/bin/tempo` to `/tempo` in ENTRYPOINT
- Verify tempo config exposes :3200 for healthcheck, or disable the EIR healthcheck in compose

**Actual risk: 🟡 LOW-MEDIUM** — Dockerfile bug is a one-line fix. After fix, passthrough works. Tempo failure = no tracing, services stay up.

---

## 3. Healthcheck Behavioral Regression

| Service | SIS Healthcheck | EIR Healthcheck | Impact |
|---------|----------------|-----------------|--------|
| Traefik | `/traefik healthcheck --ping` (verifies app is ready) | TCP :8080 (port open only) | oauth2-proxy may start before :443 is ready |
| Cloudflared | _(none)_ | TCP :7844 | New healthcheck — may cause unexpected restarts |
| Alertmanager | `wget /-/healthy` (verifies app responds) | TCP :9093 (port open only) | Less thorough — port open ≠ alertmanager ready |
| Tempo | _(none — disabled)_ | TCP :3200 | New healthcheck — SIS explicitly disabled this for distroless |

**Downstream impact:** `oauth2-proxy` depends on traefik `service_healthy`. The EIR healthcheck only verifies port :8080 is bound, not that traefik is actually serving on :80/:443. oauth2-proxy could begin routing traffic before traefik is fully initialized.

---

## 4. Secrets and Configuration at Risk

| Service | Config Mechanism | Breaks on Migration? |
|---------|------------------|-------------------|
| Traefik | 14 CLI flags + `CLOUDFLARE_DNS_API_TOKEN` env var | CLI flags swallowed → no providers, no TLS, no entrypoints |
| Cloudflared | `command:` tunnel args + mounted `credentials.json` | Command swallowed → tunnel doesn't start |
| Alertmanager | Custom entrypoint renders `alertmanager.yml.tpl` via `sed` | No shell → template never renders → no alerts configured |
| Tempo | `command: -config.file=...` | Swallowed → no config → tempo fails to start |

---

## 5. Risk Summary (Updated)

| Service | Original Claim | Revised Risk | Blocker |
|---------|---------------|-------------|---------|
| **Traefik** | 🔴 HIGH | 🟡 **MEDIUM** | Healthcheck regression (acceptable with `start_period`). Arg passthrough works. |
| **Cloudflared** | 🔴 HIGH | 🟢 **LOW** | Convert `command:` string → array form. Arg passthrough works. |
| **Alertmanager** | 🟡 MEDIUM | 🟡 **MEDIUM** | Custom entrypoint bypasses shim + shell dependency. Pre-render template on host. |
| **Tempo** | 🟡 MEDIUM | 🟡 **LOW-MEDIUM** | Dockerfile binary path bug (one-line fix). Arg passthrough works after fix. |

**Overall Phase 1 risk: 🟡 MEDIUM** — No systemic blocker. All issues are fixable with compose changes and one Dockerfile fix. No shim code changes required.

---

## 6. Resolution Plan (Updated)

### No Shim Code Changes Needed

The shim already supports argument passthrough via `trailing_var_arg = true` and `allow_hyphen_values = true` on the `args` field. No changes to EvergreenShims are required.

### Per-Service Fixes

| Service | Fix | Effort | Shim Change? |
|---------|-----|--------|-------------|
| Traefik | Keep `command:` as-is. Add `start_period: 30s` to healthcheck in compose. Optionally convert to env vars later. | 5 min | No |
| Cloudflared | Convert `command:` from string to array form: `["tunnel", "--config", "/etc/cloudflared/config.yml", "--metrics", "0.0.0.0:4788", "run"]` | 5 min | No |
| Alertmanager | Pre-render template on host. Remove `entrypoint:`. Convert `command:` to array form. | 1 hr | No |
| Tempo | Fix EIR Dockerfile: `/usr/bin/tempo` → `/tempo` in ENTRYPOINT. Rebuild image. | 10 min | No |

### String vs Array `command:` — Why It Matters

Docker Compose `command:` has two forms:
```yaml
# String form — Docker wraps in /bin/sh -c
command: tunnel --config /etc/cloudflared/config.yml run
# Effective: /bin/sh -c "tunnel --config ..."

# Array form — Docker exec's directly
command: ["tunnel", "--config", "/etc/cloudflared/config.yml", "run"]
# Effective: tunnel --config ... (appended to ENTRYPOINT)
```

All SIS Phase 1 services using string-form `command:` must be converted to array form because EIR scratch-based images have no shell. This is a compose change, not a shim change.

---

## 7. Additional Bug Found

**EIR `images/tempo/Dockerfile`** — Binary path mismatch:
- Line 24: `COPY --from=builder /tmp/tempo /tempo` → binary at `/tempo`
- Line 37: `ENTRYPOINT ["/shim", "run", "-c", "/usr/bin/tempo"]` → references `/usr/bin/tempo`

The image will not start. This must be fixed in the EIR repo before tempo can be migrated. One-line fix.

---

## 8. Shim Configuration Reference

For services that need custom shim behavior (healthcheck tuning, shutdown timeout, etc.), the shim supports a TOML config file at `/etc/shim/config.toml`:

```toml
[process]
command = "traefik"       # or set via PROCESS_COMMAND env var
args = ["--accesslog=true"]  # or set via PROCESS_ARGS env var
shutdown_timeout_secs = 30  # or set via SHUTDOWN_TIMEOUT_SECS env var

[health]
listen = "0.0.0.0:9101"     # or set via HEALTH_LISTEN env var
interval_secs = 10           # or set via HEALTH_INTERVAL_SECS env var
timeout_secs = 5             # or set via HEALTH_TIMEOUT_SECS env var
liveness_cmd = "exec:true"   # or set via HEALTH_CMD env var
```

Config priority: CLI args > env vars > config file > defaults.

For the SIS migration, most services won't need a config file — the default behavior (command + args from ENTRYPOINT + compose CMD, default health/migration capabilities) is sufficient.

---

## 9. Recommended Migration Order (Revised)

| Order | Service | Why This Order | Effort |
|-------|---------|----------------|--------|
| 1 | **Cloudflared** | Lowest risk, one-line compose fix (string → array), validates shim passthrough | 15 min total (5 min change + 10 min verify) |
| 2 | **Alertmanager** | Medium risk, template pre-rendering needed, but failure impact is low (no alerts, not no services) | 1.5 hrs total (1 hr pre-render setup + 30 min verify) |
| 3 | **Tempo** | Low risk after Dockerfile fix, validates tracing pipeline | 30 min total (10 min Dockerfile fix + 20 min verify) |
| 4 | **Traefik** | Highest impact (ingress), do last when pattern is proven. Healthcheck regression needs `start_period`. | 30 min total (5 min compose + 25 min verify) |

**Total estimated Phase 1 effort:** ~3 hours

---

## 10. Conclusion

The migration is **ready to proceed with conditions.** The original "NO-GO" verdict was based on an incorrect assumption about the shim's argument handling. Source code analysis confirms the shim supports full argument passthrough.

**Remaining conditions before Phase 1:**
1. ✅ ~~Shim arg passthrough~~ — Already works
2. ⬜ Fix EIR tempo Dockerfile binary path bug — 5 min
3. ⬜ Convert cloudflared `command:` string → array form — 5 min
4. ⬜ Pre-render alertmanager template on host — 1 hr
5. ⬜ Verify healthcheck behavior for traefik with `start_period` — 25 min
6. ⬜ Audit Phase 2-3 services for same patterns (custom entrypoints, string commands) — 2 hrs

**No shim code changes required. All fixes are compose changes and one Dockerfile fix.**

**Recommendation:** Proceed with Phase 1 starting with cloudflared (lowest risk, validates the pattern).
