Phase 2 migrates 5 medium-risk services from SIS to EIR. Each service has specific issues requiring mitigation. The key insight from Phase 1 is that **shim argument passthrough works**; the main risks are compose file adaptation, volume mounting, and custom entrypoints.
| **SIS Config** | `command:` (none; uses default), env vars for DB config |
1. ✅ No `command:` override; shim uses default
2. ⚠️ Capabilities: `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`, `SETUID`; EIR drops ALL but these are needed for Forgejo's internal user management
**Risk: 🟢 LOW**; No command override, capabilities are standard, volumes work.
1. ✅ `command: ["start"]` is already array form; works with shim
3. ✅ No volumes needed; uses PostgreSQL for state
**Risk: 🟡 MEDIUM**; Java dependency needs verification, but shim passthrough works.
1. ✅ No `command:` override; shim uses default
**Risk: 🟡 MEDIUM**; Scratch base limits debugging, but functionality should work.
1. ✅ No `command:` override; shim uses default
3. ✅ No volumes needed; used by exporter only
**Risk: 🟢 LOW**; Simple service, no persistence needed, version difference acceptable.
1. ✅ No `command:` override; shim uses default
3. ✅ No volumes needed; used by immich for caching
5. ⚠️ Capabilities: `SETUID`, `SETGID`; EIR drops ALL
**Risk: 🟢 LOW**; Simple service, no persistence, same version.