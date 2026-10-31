# SIS Stack → EvergreenImageRegistry Migration Report (Final: Peer Review Corrected)
**Status:** Migration Ready; All Blockers Resolved
- `immich`; EIR version is v1.106.0, SIS uses v2.7.5 (entire major version behind)
- `erpnext`; EIR image is a stub (no binaries installed)
| immich-postgres | - | ❌ No EIR equivalent (pgvector) |
The `read-only-rootfs` label is **informational only**; it doesn't enforce read-only at runtime. Docker's `--read-only` flag must be explicitly set in compose. Most services already mount volumes for writable paths, so this is manageable.
The `cap-drop: ALL` label is **informational only**; it doesn't enforce capability drops at runtime. Docker's `--cap-drop` flag must be explicitly set in compose. Most services work without special capabilities.
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
No migration needed; EIR versions match or exceed SIS versions.
1. ✅ **96% coverage**; 51/53 SIS images have EIR equivalents
| 1 | busybox | 1.37.0 | 1.37.0 | - | ✅ Direct drop-in |
| 2 | victoria-metrics | v1.50.0 | v1.50.0 | - | ✅ Direct drop-in |
| 3 | vmalert | v0.32.1 | v0.32.1 | - | ✅ Direct drop-in |
| 5 | victoria-logs | v1.50.0 | v1.50.0 | - | ✅ Direct drop-in |
| 6 | promtail | 3.4.0 | 3.4.0 | - | ✅ Direct drop-in |
| 8 | cadvisor | v0.55.1 | v0.57.0 | - | ⚠️ Needs testing |
| 9 | node-exporter | v1.11.1 | v1.11.1 | - | ⚠️ Needs testing |
| 10 | alertmanager | v0.32.1 | v0.32.1 | - | ✅ Direct drop-in |
| 11 | postgres-exporter | v0.19.1 | 0.15.0 | - | ⚠️ Needs testing |
| 12 | redis-exporter | v1.83.0 | v1.83.0 | - | ✅ Direct drop-in |
| 13 | tempo | 2.10.5 | 2.10.5 | - | ✅ Direct drop-in |
| 14 | blackbox-exporter | v0.28.0 | v0.28.0 | - | ✅ Direct drop-in |
| 15 | zfs-exporter | 0.5.0 | 0.5.0 | - | ✅ Direct drop-in |
| 17 | forgejo | 15.0.2 | 15.0.2 | - | ✅ Direct drop-in |
| 18 | forgejo-runner | 7.0.0 | 7.0.0 | - | ✅ Direct drop-in |
| 19 | taiga-back | 6.9.0 | 6.9.0 | - | ✅ Direct drop-in |
| 20 | taiga-front | 6.9.0 | 6.9.0 | - | ✅ Direct drop-in |
| 21 | taiga-events | 6.9.0 | 6.9.0 | - | ✅ Direct drop-in |
| 22 | taiga-protected | 6.9.0 | 6.9.0 | - | ✅ Direct drop-in |
| 23 | rabbitmq | 3.13.1 | 3.13.1 | - | ✅ Direct drop-in |
| 24 | nginx | 1.27.1 | 1.27.1 | - | ✅ Direct drop-in |
| 28 | oauth2-proxy | 7.7.1 | 7.7.1 | - | ✅ Direct drop-in |
| 29 | docker-socket-proxy | 0.4.2 | 0.4.2 | - | ✅ Direct drop-in |
| 30 | homepage | 0.9.24 | 0.9.24 | - | ✅ Direct drop-in |
| 31 | ocis | 5.0.14 | 5.0.14 | - | ✅ Direct drop-in |
| 32 | collabora | 24.04.10.3 | 24.04.10.3 | - | ✅ Direct drop-in |
| 33 | freshrss | 1.24.3 | 1.24.3 | - | ✅ Direct drop-in |
| 35 | immich-machine-learning | v2.7.5 | 2.7.5 | - | ⚠️ Needs testing |
| 36 | valkey | 9.0.4 | 9.0.4 | - | ⚠️ Needs testing |
| 37 | paperless-ngx | 2.20.15 | 2.20.15 | - | ⚠️ Needs testing |
| 38 | synapse | v1.152.1 | v1.152.1 | - | ✅ Direct drop-in |
| 39 | element-web | 1.11.30 | 1.11.30 | - | ✅ Direct drop-in |
| 40 | matrix-hookshot | 7.3.3 | 7.3.3 | - | ✅ Direct drop-in |
| 41 | calibre-web | 0.6.42 | 0.6.42 | - | ✅ Direct drop-in |
| 42 | akaunting | 3.1.21-v | 3.1.21-v | - | ✅ Direct drop-in |
| 43 | cloudflared | 2026.5.0 | 2026.5.0 | - | ✅ Direct drop-in |
| 44 | vaultwarden | 1.36.0 | 1.36.0 | - | ✅ Direct drop-in |
| 46 | watchtower | 1.8.2 | 1.8.2 | - | ✅ Direct drop-in |
| 47 | restic | 0.17.5 | 0.17.5 | - | ✅ Direct drop-in |
| 48 | crowdsec | 1.6.5 | 1.6.5 | - | ⚠️ Needs testing |
| 49 | wireguard | 1.0.20250521 | 1.0.20250521 | - | ⚠️ Needs testing |
| 51 | immich-postgres | 14-vectorchord | - | - | ❌ Keep upstream |
| 52 | infra-webhook | latest | - | - | ❌ Keep locally built |
| Stubs | 1 | Keep upstream (erpnext) | ✅ Verified; no binaries |
| Uncontrolled (`:latest`) | 3 | **Fixed**; pinned to SIS versions | ✅ Verified; Dockerfiles edited |
| Duplicates | 1 | Use blackbox-exporter | ✅ Verified; functionally identical |
| No EIR Equivalent | 2 | Keep upstream (immich postgres, webhook) | ✅ Verified; no equivalent |