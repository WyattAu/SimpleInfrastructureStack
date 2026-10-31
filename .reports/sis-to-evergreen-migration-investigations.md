### `erpnext`: STUB (Not a Real Image)
| Manifest Version | `16.0.0` (but Dockerfile label says `15.11.0`; **version mismatch**) |
| Status | **STUB**; empty wolfi-base skeleton, no application binaries or code |
### `postgresql-exporter`: EIR 4 Versions Behind
| Delta |; | 4 versions behind |
### `redis`: EIR Slightly Behind
| Delta |; | 8 patch releases behind |
### `immich`: EIR Ancient (v1 vs v2)
| Delta |; | Entire major version behind |
### `synapse`: No Version Pin
### `taiga-back`: No Version Pin
### `taiga-front`: Version Mismatch
### `taiga-events`: No Version Pin
### `taiga-protected`: Version Mismatch?
### `blackbox-exporter` vs `prometheus-blackbox-exporter`: Same Tool Built Twice
**Details:** Functionally identical; both compile the same upstream tool. The only differences are labels and that `prometheus-blackbox-exporter/` also copies a `blackbox.yml` config file.
### `ghcr.io/immich-app/postgres`: Custom Postgres with pgvector
| EIR Has It | No; EIR has generic `postgres`/`postgresql-*` but none include vectorchord/pgvector extensions |
### `infra-webhook:latest`: Locally Built
| EIR Has It | No; no webhook relay image in EIR |
## 6. SIS Custom `ghcr.io/wyattau/*` Images: Deduplication Decision
| **Total items** | **14** |; |