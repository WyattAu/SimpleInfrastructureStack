**Trigger:** Peer review of migration report identified gaps; deep audit requested
**Verdict:** **GO with conditions**; Systemic blocker resolved; per-service issues remain
## 1. Shim Argument Passthrough: Resolved
// main.rs:174-179; Args override config
// process.rs:81-82; Args forwarded to child
The issue is not the shim code; it's how the EIR Dockerfiles define their ENTRYPOINT:
# No CMD: Docker CMD defaults to empty
| "Systemic blocker; shim code change needed" | ❌ **False.** Shim already supports passthrough |
1. ✅ Shim passthrough works; all 14 CLI flags will be forwarded to traefik correctly
2. ⚠️ Healthcheck downgrades from app-level ping (`/traefik healthcheck --ping`) to port-level TCP check (`--tcp 127.0.0.1:8080`). oauth2-proxy depends on traefik `service_healthy`; may start before :443 is ready.
- Remove the EIR built-in HEALTHCHECK from compose and restore the SIS healthcheck: `test: ["CMD", "/traefik", "healthcheck", "--ping"]`; but wait, `scratch` base has no shell. The `/traefik` binary may not support direct invocation from healthcheck CMD.
- Alternative: use the EIR healthcheck HTTP mode if traefik exposes a readiness endpoint: `CMD ["/shim", "healthcheck", "--http", "http://127.0.0.1:8080/ping"]`; but EIR healthcheck only does TCP connect, not HTTP request parsing.
**Actual risk: 🟡 MEDIUM**; Arg passthrough works. Healthcheck is slightly less thorough but acceptable. Traefik is still the ingress; any config error takes down everything, but that's true regardless of image source.
2. ✅ If converted to array form (`command: ["tunnel", "--config", "/etc/cloudflared/config.yml", "--metrics", "0.0.0.0:4788", "run"]`), shim passthrough works; all args forwarded to cloudflared.
3. ✅ The EIR adds a TCP healthcheck on :7844; new but harmless since cloudflared binds this port.
**Actual risk: 🟢 LOW**; Shim passthrough works after converting command to array form. No other issues. Cloudflared is external access but the change is trivial.
| **Custom entrypoint:** | `stacks/monitoring/alertmanager/entrypoint.sh`; renders `alertmanager.yml` from template via `sed` substitution of `$NTFY_TOPIC` |
2. ❌ The custom entrypoint uses `sed` and `#!/bin/sh`; neither exists in the `scratch`-based EIR image.
**Actual risk: 🟡 MEDIUM**; Requires pre-rendering workflow change. Alertmanager failure = no alerts, but services keep running.
| **SIS healthcheck:** | _(none; commented out: "Tempo 2.10+ is distroless")_ |
3. ⚠️ The EIR adds a TCP healthcheck on :3200; SIS had this disabled. Tempo 2.10+ is distroless. The healthcheck port should be verified against the tempo config.
**Actual risk: 🟡 LOW-MEDIUM**; Dockerfile bug is a one-line fix. After fix, passthrough works. Tempo failure = no tracing, services stay up.
| Cloudflared | _(none)_ | TCP :7844 | New healthcheck; may cause unexpected restarts |
| Alertmanager | `wget /-/healthy` (verifies app responds) | TCP :9093 (port open only) | Less thorough; port open ≠ alertmanager ready |
| Tempo | _(none; disabled)_ | TCP :3200 | New healthcheck; SIS explicitly disabled this for distroless |
**Overall Phase 1 risk: 🟡 MEDIUM**; No systemic blocker. All issues are fixable with compose changes and one Dockerfile fix. No shim code changes required.
### String vs Array `command:`: Why It Matters
# String form: Docker wraps in /bin/sh -c
# Array form: Docker exec's directly
**EIR `images/tempo/Dockerfile`**; Binary path mismatch:
For the SIS migration, most services won't need a config file; the default behavior (command + args from ENTRYPOINT + compose CMD, default health/migration capabilities) is sufficient.
1. ✅ ~~Shim arg passthrough~~; Already works
2. ⬜ Fix EIR tempo Dockerfile binary path bug; 5 min
3. ⬜ Convert cloudflared `command:` string → array form; 5 min
4. ⬜ Pre-render alertmanager template on host; 1 hr
5. ⬜ Verify healthcheck behavior for traefik with `start_period`; 25 min
6. ⬜ Audit Phase 2-3 services for same patterns (custom entrypoints, string commands); 2 hrs