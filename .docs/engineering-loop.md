# Engineering loop

This repository runs a continuous engineering loop. This document is the
loop's persistent state: read it first in every session, append the
iteration log, and leave the next iteration queued. If this file is
accurate, any session can pick the loop up cold.

---

## The loop contract

```text
ANALYZE ──► ROADMAP ──► IMPLEMENT ──► TEST ──► VERIFY ──┐
   ▲                                                     │
   └─────────────────────────────────────────────────────┘
```

1. **ANALYZE** — verify fleet reality (EIR runs, container health, backup
   freshness) and **RESEARCH**: pull current papers/docs/release notes on
   topics gating the roadmap. Research findings must be written down here
   with links, even when the answer is "nothing changed".
2. **ROADMAP** — re-rank the backlog below against what analysis and
   research just showed. Kill stale items. The roadmap is a hypothesis
   until iteration proves otherwise.
3. **IMPLEMENT** — one coherent deliverable per iteration (a repo, a
   feature slice, a fix wave). Dogfood the estate's own crates first;
   upstream only when no estate crate exists.
4. **TEST** — unit + integration in-repo; render/syntax validation for
   infrastructure code.
5. **VERIFY** — run the real built artifact against a real fixture
   (binary + curl, not only `cargo test`), plus a fleet-level check.
6. **LOG** — append the iteration to this file, update the backlog and
   the dogfooding matrix, commit.

Stop condition: never. "Nothing to work on" is a symptom of a stale
backlog, not a finished ecosystem — regenerate the backlog from research
when it thins.

### Standing rules

- New Rust repos follow `OmniRust-template` posture: workspace `crates/*`,
  edition 2021, tier-a lints (deny panic/unwrap/expect/unsafe, pedantic),
  Apache-2.0.
- Published-crates.io deps preferred; git deps are debt to be repaid by
  republishing upstream.
- Websites/frontends: Astro + SolidJS (`pediment` for tokens/components).
- Fleet changes to SIS `main` auto-deploy TrueNAS — push deliberately.

---

## Dogfooding matrix

Estate crates (all published on crates.io) and who consumes them. Goal:
every shipping stack sits on estate crates, and every estate crate has ≥2
consumers.

| Estate crate | Consumers | Status |
| --- | --- | --- |
| `telemetry-init` 0.1 | **hosting-api** | live |
| `metrics-kit` 0.1 | **hosting-api** (via telemetry-init) | live |
| `worker-kit` | hosting-api v1 (backup job queue) | planned |
| `outbox-kit` | hosting-api v1 (durable backup events) | planned |
| `billing-kit` / `ledger-kit` | hosting-metering (iteration ≥3) | planned |
| `policy-kit` | hosting-api authz (edge-delegated for now) | planned |
| `scim-kit` / `webauthn-kit` | hosting-dashboard auth | planned |
| `pediment` | hosting-dashboard | planned |
| `ferro` | SIS production; `files` tenant template | live |
| `Tachyon` | SIS production | live |
| EIR images | 34+ SIS containers; all tenant templates | live |

Consumers wanted (offer these crates to them): `civitforge`, `clawdius`,
`kestrel`, `aether-core`.

---

## Iteration log

### Iteration 0 — 2026-10-06 — loop bootstrap + hosting-api

#### ANALYZE

- EIR: lint/daily-scans/compliance green. Smoke Test red since Sep 15 —
  root-caused during this iteration (see below). Nightly still red.
- SIS: backups green (6+ consecutive, offsite OK), fleet healthy.

#### RESEARCH (findings → roadmap effects)

1. *Tenant isolation* — gVisor (userspace kernel, runsc, per-sandbox
   Sentry+Gofer; syscall overhead; compatibility gaps) vs Firecracker
   (Rust microVM on KVM, <125 ms boot, <5 MiB, jailer; used by Fly.io,
   Kata). Both run on the EPYC/KVM plan. **Decision**: pilot stays on
   Docker + resource limits; growth path is per-tenant Firecracker
   microVM (hard boundary, no docker-in-docker) with gVisor as the
   compatibility-friendly alternative for syscall-heavy tenants.
2. *Non-root containers* (Docker userns-remap docs) — daemon-level
   `userns-remap` re-maps container root to unprivileged host UIDs, making
   even root-running upstream images safe, at the cost of bind-mount
   ownership pre-arrangement and no host networking (cAdvisor would need
   `--userns=host`). **Decision**: this is the systemic control for
   docker01 — beats fixing 58 upstream-derived Dockerfiles one by one.
   The EIR audit is still required for catalog honesty, but becomes
   defense-in-depth rather than the primary control. Add
   `userns-remap: default` to docker01's daemon.json (Ansible) in a later
   iteration with a data-dir chown migration (subuid range).
3. *Metering* — OpenMeter (now Kong/Tailfin) is the reference shape:
   event ingestion → aggregation → entitlements → Stripe sync, with
   OpenTelemetry collectors as first-class ingest. **Decision**: billing
   for hosting should be OTLP/metrics-shaped (cAdvisor per-tenant CPU/mem
   - storage gauges) flowing through estate crates (`billing-kit`,
   `ledger-kit`) rather than a bespoke invoice cron.
4. *Frontend versions* — Astro 7.3.5, Solid 1.9.15, Starlight 0.42.5
   (verified against npm registry). Dashboard work targets these.

#### IMPLEMENT

- Created [`hosting-api`](https://github.com/WyattAu/hosting-api) — the
  control plane the deferred customer dashboard needs. Endpoints:
  healthz, metrics, tenant list/detail (live compose status), backup
  trigger with per-tenant RAII gate. Secrets structurally excluded from
  API types; slug traversal rejected pre-join; subprocesses
  timeout-bounded. 16 tests; verified against the real binary end-to-end
  (fixture tenants, metrics exposition, zero secret leakage).

#### TEST/VERIFY findings that changed the code

- Jinja/Go-template collision class (fixed in watchdog template last
  iteration) recurred in Rust land as dependency skew: published
  `telemetry-init` 0.1.1 → `metrics-kit` 0.1 while main moved to 0.2
  unpublished; published `testkit` 0.2.2 lacks `http::TestServer` that
  main has. Pinned to what crates.io resolves; recorded as upstream
  republish debt. **Dogfooding found the skew — that is the loop
  working.**

### Iteration 1 — 2026-10-06 — EIR FIPS wave + nightly verification

#### ANALYZE

- Build FIPS Variants red: every job failed instantly. Two independent
  root causes (both fixed this iteration):
  1. `IMAGE_PREFIX: ${{ github.repository_owner }}` → `WyattAu` (upper)
     — GHCR rejects uppercase repository names. Fixed by lowercasing into
     `GITHUB_ENV` per job, mirroring `_build-reusable.yml`.
  2. `build-keycloak-fips` referenced `images/keycloak/manifest.toml`,
     but an automated bump renamed the dir to `keycloak-quarkus/` and the
     rename left no `Dockerfile.fips` — empty version tag even before the
     prefix bug. Job removed from the matrix; a purpose-built
     keycloak-quarkus FIPS variant is backlog #10.
- Upstream Version Watch still red — the known PR-permission block
  (user action: enable "Allow GitHub Actions to create and approve pull
  requests" in repo settings). Unchanged.

#### VERIFY (nightly)

- Oct 5 Nightly Full Rebuild: **all 25 jobs succeeded**, including every
  build batch (oxidized + alertmanager fixes confirmed in a full build).
  The run-level conclusion says "failure" while no job or step failed
  (API evidence: 25/25 success, run_attempt 1) — logged as a GH
  quirk; confirm on the Oct 6 nightly before treating red as real.
- The 3 unhealthy exporters stay unhealthy until the next SIS deploy
  pulls rebuilt shim-equipped images — expected; watchdog exempts them.

#### IMPLEMENT

- EIR `8591a717f`: FIPS lowercase fix + keycloak variant removal.
  (Pre-push gate caught a trailing-blank-line, fixed in a follow-up
  style commit — the gate-as-formatter loop is normal now.)

### Iteration 2 — queued

1. **hosting-api v1**: `worker-kit`-driven backup job queue (async
   trigger → job status endpoint), `outbox-kit` for durable job events,
   bearer-token auth (so the edge can proxy it safely), systemd unit +
   Ansible wiring for docker01.
2. **EIR estate republish wave**: publish telemetry-init 0.1.2 (metrics-kit
   0.2 dep) and testkit 0.3.0 (http module) to repay skew debt; then bump
   hosting-api deps off the 0.1 pins.
3. **hosting-dashboard scaffold**: Astro 7 + SolidJS 1.9 + pediment,
   consuming hosting-api; login via edge (oauth2-proxy) first.
4. Confirm Oct 6 nightly conclusion quirk (all-jobs-green run marked
   failure) — if it recurs, file upstream with evidence.

## Backlog (ranked)

| # | Item | Why |
| --- | --- | --- |
| 1 | hosting-api v1 (jobs + auth + Ansible wiring) | dashboard needs it; dogfoods worker-kit/outbox-kit |
| 2 | EIR FIPS tag fix + nightly triage | red pipeline = product quality claim is false |
| 3 | EIR non-root USER audit (58 critical images) — classify runtime-drops-privileges vs actual-root | honest security posture; userns-remap makes it defense-in-depth |
| 4 | docker01 daemon `userns-remap` + subuid migration (Ansible) | systemic tenant containment |
| 5 | hosting-dashboard (Astro+SolidJS+pediment) | customer-facing surface |
| 6 | hosting-metering (cadvisor→billing-kit→ledger-kit) | usage-based add-on billing |
| 7 | Firecracker per-tenant microVM spike (staging VM) | isolation growth path, validated before it is needed |
| 8 | vane evaluation as edge replacement on staging | own-stack moat; routes translate from Caddyfile 1:1 |
| 9 | estate republish wave (telemetry-init, testkit, then dependents) | repay git-skew debt; unblocks crates.io-only consumers |

## Research queue

- Firecracker + containerd or jailer-only per-tenant layouts; cold-boot
  cost per tenant stack (docs + fly.io engineering blog)
- gVisor syscall overhead numbers for DB workloads (Postgres/Redis under
  runsc — Google's production guide)
- systemd-creds / SOPS-on-host secrets for docker01 (currently SOPS →
  /etc/sis-hosting at deploy time)
- Astro 7 islands + SolidJS hydration cost vs SPA for the dashboard
- OCI image signatures in practice: cosign verify at docker01 pull time
  (EIR already attests — enforce on the consumer side)
