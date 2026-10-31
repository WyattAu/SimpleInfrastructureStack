**Status:** Analysis Complete; Migration Blocked on Multiple Fronts
1. **`command:` overrides may conflict**; The shim wraps the command, so `command: redis-server --appendonly yes` gets passed through the shim's `-c` flag. If the shim expects a specific command format, this breaks.
2. **Healthcheck definitions change**; SIS uses `CMD-SHELL` or `CMD` healthchecks. EIR uses the shim's built-in healthcheck. You'd need to either:
3. **Entrypoint/CMD interaction**; EIR images use `ENTRYPOINT ["/shim", "run", "-c", "app"]` with `CMD ["-c", "app-binary", "--", "args"]`. SIS compose files that override `entrypoint:` or `cmd:` would bypass the shim entirely.
Many EIR images use `scratch` as the final stage; the most minimal possible base:
# EIR scratch image: sh doesn't exist
| blackbox-exporter | - | scratch | ❌ No |
| node-exporter | - | scratch | ❌ No |
# EIR image: CAP_DROP ALL means no SYS_ADMIN
# EIR image: CAP_DROP ALL, no NET_ADMIN
1. **traefik**; Most critical, validates shim pattern
2. **cloudflared**; Simple, validates shim pattern
3. **alertmanager**; Simple, validates shim pattern
4. **tempo**; Simple, validates shim pattern
1. **forgejo**; Test entrypoint, volumes, SSH
2. **keycloak**; Test entrypoint, database init
3. **grafana**; Test plugin loading, dashboard volumes
4. **redis**; Test command overrides, persistence
5. **valkey**; Test compatibility
1. **postgres**; Test init scripts, extensions
2. **node-exporter**; Test /proc, /sys mounts
3. **cadvisor**; Test Docker socket access
4. **paperless-ngx**; Test s6-overlay, tesseract, poppler
- Immich (main; EIR version ancient)
**Answer:** Yes; EIR's immich is too old. Keep upstream immich images.
1. **Health-shim wrapper**; Changes entrypoint/CMD structure for all services
2. **Read-only rootfs**; Requires tmpfs mounts for writable paths
3. **Scratch-based images**; No shell for debugging
4. **Capability drops**; Breaks cadvisor, wireguard, crowdsec
5. **36 images with no EIR equivalent**; Can't migrate those at all
**Recommendation:** Proceed with Phase 1 (4 low-risk services) to validate the pattern, then decide on Phase 2-3 based on results. The health-shim pattern is the single biggest risk factor; if it works cleanly with SIS compose files, migration becomes much more feasible.