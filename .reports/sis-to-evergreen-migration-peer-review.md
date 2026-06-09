# Peer Review: SIS → EvergreenImageRegistry Migration Report (Final)

**Reviewer:** Nexus (Principal Systems Architect)
**Date:** 2026-06-09
**Review Type:** Technical Accuracy & Completeness
**Report Under Review:** `.reports/sis-to-evergreen-migration-report.md`

---

## Verdict: Approved with Required Corrections

The report is a solid decision document for the migration. It correctly identifies what exists in EIR, classifies risk, and proposes a phased migration. The structure is clean and actionable. However, there are **3 factual errors** and **2 structural gaps** that must be fixed before the report can be used as a basis for implementation.

---

## 1. Factual Errors

### 1.1 Coverage Math Does Not Add Up

**Claim:** "52 images with EIR equivalent" / "52/53 (98%)"

**Problem:** Section 2 names only 23 images (10 direct + 10 conditional + 3 keep upstream). The remaining 30 SIS images are unaccounted for. Since the report doesn't list them, a reader cannot verify coverage.

**Fix:** Either:
- Expand the matrix to list all 53 images, or
- Add a sentence explaining that the remaining 30 images were verified against EIR in a separate audit (with link) and all matched.

### 1.2 Appendix A Is Incomplete

**Claim:** "Complete Version Inventory"

**Problem:** Appendix A lists only 13 images out of 53. The title says "complete" but it is not. The remaining 40 images (prometheus, postgres-exporter, redis-exporter, uptime-kuma, victoria-metrics, vmalert, traefik, cloudflared, alertmanager, tempo, nginx, synapse, taiga-back, taiga-events, erpnext, taiga-front, taiga-protected, rabbitmq, nginx, mariadb, redis, postgres, grafana, keycloak, forgejo, node-exporter, cadvisor, paperless-ngx, valkey, immich, immich-ml, immich-postgres, prom/blackbox-exporter, grafana/promtail, plus ~16 more) are missing from the table.

**Fix:** Expand Appendix A to list all 53 images. Without this, the coverage claim is unverifiable.

### 1.3 infra-webhook Double-Counted

**Problem:** Section 2 lists 3 images under "Keep Upstream": immich, immich-postgres, infra-webhook. But the executive summary says only 1 image lacks an EIR equivalent (immich). If infra-webhook genuinely has no EIR equivalent, then coverage is 51/53 (96%), not 52/53 (98%).

**Fix:** Clarify one of:
- If infra-webhook now has an EIR equivalent: move it to Section 2 and update coverage to 52/53
- If it doesn't: update coverage to 51/53 and executive summary to "1 image must stay upstream"
- Count immich-main as the single unresolvable image (immich-postgres is a dependency of immich-main, not a separate SIS service)

---

## 2. Structural Gaps

### 2.1 Investigation Resolutions Are Unverified

Appendix B says "All resolved" for all 14 items. But several resolutions are aspirational, not executed:

| Item | Claimed Resolution | Verification Status |
|------|-------------------|---------------------|
| postgresql-exporter (0.15.0) | "Accept EIR version" | Not verified — 4 versions behind may break query compatibility |
| redis (7.4.1) | "Accept EIR version" | Not verified — acceptable, but should be documented as accepted risk |
| Custom Image Dedup (4 items) | "Switch to EIR" | Not verified — Dockerfiles haven't been compared yet |
| `:latest` pins (3 items) | "Fixed" | Not verified — were EIR Dockerfiles actually edited? |

**Fix:** Either:
- Add verification evidence (link to commit/PR, or "verified on server" flag), or
- Change "Resolution" to "Decision: [action]" to make clear these are decisions, not completed work

### 2.2 Appendix B Is Not Linked to Investigation Details

Appendix B is a summary table with one-line resolutions. The full investigation details (what exactly was wrong, what was tested, what the outcome was) are in the separate investigations file. But that file is no longer referenced.

**Fix:** Add a one-liner reference: `Full details: .reports/sis-to-evergreen-migration-investigations.md`

This ensures audit trail is preserved.

### 2.3 Custom Image Dedup Missing Details

Appendix B says "Switch to EIR" for 4 custom images but doesn't list which ones or what the comparison found. The reader can't act on this without knowing:
- Which custom images (`ghcr.io/wyattau/forgejo`, etc.)
- What was found (Dockerfile comparison results)
- What decision was made and when

**Fix:** Add to Appendix B or create a one-line reference to the investigation details.

---

## 3. Good Decisions in Your Changes

### 3.1 Section 1 Coverage Summary — Good

Adding a top-level summary box is the right call. Readers immediately see 98% coverage without scrolling. Keep this.

### 3.2 Synapse/Taiga Promoted to Direct Drop-in — Needs Caveat

You moved `synapse`, `taiga-back`, and `taiga-events` from "Conditional" to "Direct Drop-in." This is correct if the `:latest` → pinned version issue was actually fixed. But Section 4 still shows the generic shim pattern without addressing how pinned images interact with the `-c` flag.

**Recommendation:** Add a note: "EIR images for synapse, taiga-back, taiga-events have been pinned to their SIS versions in EIR. Verify that pinned images behave identically to upstream."

### 3.3 Appendix B Summary — Good

Replacing the verbose investigation items with a compact resolution table is the right editorial choice for a final report. Keep this structure.

### 3.4 Removed Shim Architecture Section

You removed the section explaining WHY the shim approach is superior. I believe this was a good removal — it doesn't belong in a migration report (it belongs in an ADR or CLAUDE.md). If you want to preserve the architectural rationale, add it to:
- `.adrs/evergreen-shim-pattern.md`, or
- `docs/architecture/` as part of the infrastructure documentation

---

## 4. Recommended Fixes (Priority Order)

| Priority | Fix | Effort |
|----------|-----|--------|
| **P0** | Fix coverage math (1.1) — either expand matrix or add audit reference | 15 min |
| **P0** | Fix infra-webhook double-count (1.3) — clarify coverage number | 5 min |
| **P0** | Expand Appendix A to all 53 images (1.2) | 30 min |
| **P1** | Add investigation reference to Appendix B (2.2) | 2 min |
| **P1** | Add verification status to Appendix B resolutions (2.1) | 15 min |
| **P1** | Add custom image dedup details (2.3) or reference | 10 min |
| **P2** | Add caveat for pinned images to Section 4 (3.2) | 5 min |

**Total effort:** ~1.5 hours

---

## 5. What NOT to Change

- **Section 3 (LTS)** — Correct and useful. Don't touch.
- **Section 4 (Health-Shim Compatibility)** — Correct pattern. Don't touch.
- **Section 5 (Read-Only Root FS)** — Correct note about informational labels. Don't touch.
- **Section 6 (Capabilities)** — Correct solutions. Don't touch.
- **Section 7 (Migration Phases)** — Correct phasing. Don't touch.
- **Section 8 (Server Test Results)** — Keep as-is (they're empirical data).

---

## 6. Items Still Requiring Your Decision

These are decisions I flagged but are **your call**, not mine:

| Item | Question | Your Options |
|------|---------|-------------|
| postgresql-exporter | Accept 0.15.0 (4 versions behind)? | Accept | Upgrade EIR | Keep upstream |
| redis | Accept 7.4.1 (8 patches behind)? | Accept | Upgrade EIR | Keep upstream |
| immich-postgres | Should immich and immich-postgres be counted as 1 or 2 "no EIR equivalent" items? | Count as 1 (same application) | Count as 2 |
| infra-webhook | Does it actually have an EIR equivalent now? | If yes: update coverage | If no: 51/53 coverage |

Once you resolve these, the report is ready for implementation.
