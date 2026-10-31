# Infrastructure Problem Report: 2026-06-11
- **P0 (Critical):** 1; Win11 runner offline
- **P1 (High):** 5; EIR image defects, supply chain exposure, plaintext secrets
- **P2 (Medium):** 6; Unhealthy services, resource pressure, CI code failures
- **P3 (Low):** 3; Monitoring gaps, documentation drift
| **Root Cause** | Unknown; VM reports RUNNING but no guest agent, no SSH, no network |
### P1-001: Vaultwarden EIR Migration Failed: Dynamic Linking
| **Symptom** | `Error: io error: No such file or directory (os error 2)`; binary crashes immediately |
| **Status** | **OPEN**; reverted to upstream, EIR image exists on GHCR but is non-functional |
### P1-002: Watchtower EIR Migration Failed: Docker Socket Permissions
| **Status** | **RESOLVED**; reverted to upstream, by design |
| **Remediation** | This is **by design**; Ansible decrypts SOPS-encrypted files and deploys plaintext `.env` to TrueNAS. The threat model is: git repo is encrypted, TrueNAS disk is encrypted (ZFS), network access is restricted. For additional protection, consider mounting encrypted tmpfs or using Docker secrets. |
| **Status** | **ACCEPTED RISK**; design is intentional, documented here for awareness |
| **Affected** | Forgejo (wolfi), Valkey (wolfi); both used `/shim` in healthcheck but binary is at `/usr/local/bin/shim` |
| **Status** | **OPEN**; pre-existing, not addressed this session |
| **Status** | **OPEN**; application-level, not infra responsibility |
| **Status** | **ACCEPTED RISK**; monitored, no action currently planned |
| **Status** | **OPEN**; developer responsibility |
| **Status** | **PARTIALLY RESOLVED**; works via compose override, EIR Dockerfile still has bug |
| `calibre-web` | Stub; no application code downloaded, only `ca-certificates` installed |
| **Status** | **OPEN**; EIR images exist but are non-functional |
| **Status** | **OPEN**; needs EIR image redesign with wolfi-base or custom init wrapper |
- **Unhealthy:** 1 (storage-collaboration; pre-existing)
- **Runner ID:** 88 (windows-latest label); offline
1. **Fix Win11 VM**; Need SPICE console access or VM rebuild to restore Windows CI capability
2. **Fix EIR oauth2-proxy Dockerfile**; Add `-c /oauth2-proxy` to ENTRYPOINT, remove compose override
3. **Standardize EIR shim path**; All images should install shim to `/usr/local/bin/shim` (add symlink `ln -s /usr/local/bin/shim /shim` in scratch images)
4. **Add binary type check to EIR CI**; Automated `file` check on every built binary; fail if dynamically linked on scratch base
5. **Migrate 15 straightforward images**; postgres, redis, nginx, synapse, etc. These are single-binary services with minimal deps
6. **Fix 4 broken EIR images**; homepage, calibre-web, crowdsec, collabora need Dockerfile rewrites
7. **Vaultwarden EIR redesign**; Switch from scratch to wolfi-base, install required shared libs
8. **OCIS EIR redesign**; Create init wrapper binary or use wolfi-base with shell
9. **CachyOS resource optimization**; Evaluate moving dev stacks to separate host
10. **Monitoring alerts**; Wire alertmanager → ntfy pipeline for container health