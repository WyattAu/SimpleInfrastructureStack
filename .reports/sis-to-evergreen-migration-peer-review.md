| postgresql-exporter (0.15.0) | "Accept EIR version" | Not verified; 4 versions behind may break query compatibility |
| redis (7.4.1) | "Accept EIR version" | Not verified; acceptable, but should be documented as accepted risk |
| Custom Image Dedup (4 items) | "Switch to EIR" | Not verified; Dockerfiles haven't been compared yet |
| `:latest` pins (3 items) | "Fixed" | Not verified; were EIR Dockerfiles actually edited? |
### 3.1 Section 1 Coverage Summary: Good
### 3.2 Synapse/Taiga Promoted to Direct Drop-in: Needs Caveat
### 3.3 Appendix B Summary: Good
You removed the section explaining WHY the shim approach is superior. I believe this was a good removal; it doesn't belong in a migration report (it belongs in an ADR or CLAUDE.md). If you want to preserve the architectural rationale, add it to:
| **P0** | Fix coverage math (1.1); either expand matrix or add audit reference | 15 min |
| **P0** | Fix infra-webhook double-count (1.3); clarify coverage number | 5 min |
- **Section 3 (LTS)**; Correct and useful. Don't touch.
- **Section 4 (Health-Shim Compatibility)**; Correct pattern. Don't touch.
- **Section 5 (Read-Only Root FS)**; Correct note about informational labels. Don't touch.
- **Section 6 (Capabilities)**; Correct solutions. Don't touch.
- **Section 7 (Migration Phases)**; Correct phasing. Don't touch.
- **Section 8 (Server Test Results)**; Keep as-is (they're empirical data).