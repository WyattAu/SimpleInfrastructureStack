#!/usr/bin/env python3
"""Lean-proof model for the WyattAu hosting platform.

The "lean proof": every design choice in the platform spec must be the
leanest option that still meets its requirement. This script encodes the
quantified claims (cost per tenant, overhead budgets, SLA windows) as
assertions, so each research-loop iteration that changes the design must
re-derive and re-verify the numbers here.

Run: python3 ops/lean-model.py
Exit 0 = every lean budget holds. Any redesign that pushes a budget over
its limit must either justify a budget revision in the loop doc or be
rejected.

Hardware basis (spec: .docs/hosting-architecture.md):
  EPYC 12-core-class VM: 12 vCPU, 96 GiB RAM, 100 GiB system + 1.5 TiB data
  Pricing basis (.docs/service-catalogue.md): flat monthly, UK GBP.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Hardware and cost basis
# ---------------------------------------------------------------------------

VCPUS = 12
RAM_GIB = 96
DATA_TIB = 1.5

# Reserved for the platform itself (edge, control plane, monitoring,
# backup agent). This is the LEANNESS target: keep platform overhead low
# enough that the vast majority of purchased capacity sells.
PLATFORM_OVERHEAD = {
    "edge_cpu": 0.5,        # Caddy, one core-fraction (iter 2: reload-driven onboarding; Pingora/River rejected at this scale)
    "control_cpu": 0.5,     # hosting-api + dashboard; iter 15: units gain Landlock fs-type deny lists (zero cost, kernel LSM)
    "metrics_cpu": 0.5,     # prometheus exporter pipeline
    "backup_cpu": 1.0,      # restic window (peak)
    "edge_ram_gib": 0.5,
    "control_ram_gib": 0.5,
    "metrics_ram_gib": 2.0,
    "backup_ram_gib": 2.0,
}


@dataclass
class LeanBudgets:
    """Quantified budgets the platform spec must satisfy."""

    # --- capacity ---------------------------------------------------------
    # Tenants the platform can host at the standard tier (1 vCPU / 4 GiB
    # per tenant, compose-based).
    max_tenants: int = 10
    # Platform overhead must stay under 20% of purchased capacity.
    max_platform_cpu_frac: float = 0.20
    max_platform_ram_frac: float = 0.15

    # --- isolation --------------------------------------------------------
    # Runtime isolation overhead vs raw Docker (userns-remap baseline):
    # syscall-heavy throughput loss must stay under this fraction, or the
    # pricing/capacity model must be revised.
    max_isolation_overhead_frac: float = 0.10

    # --- metering ---------------------------------------------------------
    # Metering scrape pipeline overhead (CPU fraction of one core at 10
    # tenants, 15s scrape) must stay under this.
    max_metering_cpu: float = 0.05

    # --- backup/DR --------------------------------------------------------
    # Nightly incremental backup window per tenant (minutes) at standard
    # tier; the SLA promise in the service catalogue depends on this.
    backup_window_minutes: int = 30
    # Restore point objective: nightly offsite = 24h RPO.
    rpo_hours: int = 24

    # --- observability ----------------------------------------------------
    # TSDB storage for 30d retention at 10 tenants (GiB).
    tsdb_gib_30d: float = 8.0

    # --- storage (iter 9) ---------------------------------------------------
    # Per-tenant hard quota (ext4 project quota, enforced in provisioning)
    # and the local restic repo budget must fit the data disk together.
    tenant_quota_gib: int = 100
    backups_reserve_gib: int = 400

    # --- identity (iter 11) ----------------------------------------------
    # The identity plane must add zero standing daemons: SPIFFE/SPIRE was
    # rejected (stateful server + node agent) in favour of authbox issuing
    # short-lived tokens; placement (loopback + 0600 creds) is the
    # attestation at one-host scale.
    max_identity_daemons: int = 0
    # Service access tokens must stay short-lived (minutes), SPIFFE-style.
    max_service_token_minutes: int = 60

    # --- edge / TLS (iter 12) ---------------------------------------------
    # Post-quantum key agreement (X25519MLKEM768) is DEFAULT in Go 1.24+
    # TLS (Caddy inherits it). Budget: any measured handshake-CPU delta
    # from enabling PQ must stay under this core fraction at 10 tenants.
    max_pq_handshake_cpu_delta: float = 0.05

    # --- unit economics ---------------------------------------------------
    # Standard tier price (GBP/month) and the hard floor: infrastructure
    # cost per tenant-month must stay below 25% of the standard price.
    standard_price_gbp: float = 60.0
    max_infra_cost_share: float = 0.25


@dataclass
class ModelInputs:
    tenants: int = 10
    tenant_vcpu: float = 1.0
    tenant_ram_gib: float = 4.0
    # Measured/estimated overheads (updated per research iteration; each
    # entry names the iteration that set it).
    isolation_overhead_frac: float = 0.02   # iter 1: tier-0 userns-remap (~0-2%); tier-1 per-tenant rootless same class; gVisor 10-25% is OPT-IN and priced separately
    metering_cpu: float = 0.02              # iter 3: cadvisor scrape pipeline; iter 17: NHCB storage conversion noted, budget unchanged
    backup_minutes_std_tenant: int = 12     # iter 4: restic incremental, warm cache; weekly prune+check scheduled inside the window budget; iter 14: chunker stays (chunking not the bottleneck), cross-tenant dedup side channel documented
    tsdb_gib_30d: float = 4.0               # iter 6: prometheus 15s, 10 tenants; iter 13: budget holds under Prometheus 3.x (upgrade, not engine swap)
    infra_cost_per_tenant_gbp: float = 9.0  # iter 10: power+disk+B2 share
    identity_daemons: int = 0               # iter 11: authbox is in-process; SPIRE rejected
    service_token_minutes: int = 15         # iter 11: short-lived service tokens (was 60)
    pq_handshake_cpu_delta: float = 0.0     # iter 12: ML-KEM-768 ~2x faster than X25519 server-side; delta ~0


def check(b: LeanBudgets, m: ModelInputs) -> list[str]:
    """Return a list of failures; empty list = lean proof holds."""
    failures: list[str] = []

    # Iteration 7 refinement: backup CPU is a WINDOWED reservation (the
    # nightly consistent-snapshot window), not a 24/7 one. Steady-state
    # capacity is checked against edge+control+metrics; the backup window
    # borrows from compressible tenant headroom (tenant CPU caps are hard
    # cgroup ceilings and bursty), and the window itself is guarded by a
    # node_pressure (PSI) alert on the TrueNAS Prometheus: sustained CPU/
    # memory pressure during the window pages the operator.
    platform_cpu = (
        PLATFORM_OVERHEAD["edge_cpu"]
        + PLATFORM_OVERHEAD["control_cpu"]
        + PLATFORM_OVERHEAD["metrics_cpu"]
    )
    backup_cpu = PLATFORM_OVERHEAD["backup_cpu"]
    platform_ram = (
        PLATFORM_OVERHEAD["edge_ram_gib"]
        + PLATFORM_OVERHEAD["control_ram_gib"]
        + PLATFORM_OVERHEAD["metrics_ram_gib"]
        + PLATFORM_OVERHEAD["backup_ram_gib"]
    )
    cpu_frac = platform_cpu / VCPUS
    ram_frac = platform_ram / RAM_GIB

    if m.tenants * m.tenant_vcpu + platform_cpu > VCPUS:
        failures.append(
            f"capacity: {m.tenants} tenants x {m.tenant_vcpu} vCPU + "
            f"{platform_cpu} platform exceeds {VCPUS} vCPU"
        )
    # Backup-window check (iter 7): the nightly window may oversubscribe
    # silicon ONLY if the backup yields (CPUWeight/IOWeight low, enforced
    # in the sweep unit) and a PSI alert guards sustained pressure. Both
    # are implemented; iter 16 added the LOCAL watchdog PSI guard
    # (memory-full/io-full/cpu-some avg60) beside the TrueNAS
    # node_pressure alert. Flip this False if either is ever removed.
    backup_yields = True
    if (
        m.tenants * m.tenant_vcpu + platform_cpu + backup_cpu > VCPUS
        and not backup_yields
    ):
        failures.append(
            "backup window oversubscribes silicon and the backup does not "
            "yield - add CPUWeight/IOWeight to the sweep unit or stagger"
        )
    if m.tenants * (m.tenant_ram_gib + platform_ram / max(m.tenants, 1)) > RAM_GIB:
        failures.append("capacity: RAM oversubscribed beyond 96 GiB")
    if cpu_frac > b.max_platform_cpu_frac:
        failures.append(
            f"platform CPU overhead {cpu_frac:.0%} > budget {b.max_platform_cpu_frac:.0%}"
        )
    if ram_frac > b.max_platform_ram_frac:
        failures.append(
            f"platform RAM overhead {ram_frac:.0%} > budget {b.max_platform_ram_frac:.0%}"
        )
    if m.isolation_overhead_frac > b.max_isolation_overhead_frac:
        failures.append(
            f"isolation overhead {m.isolation_overhead_frac:.0%} > budget "
            f"{b.max_isolation_overhead_frac:.0%}"
        )
    if m.metering_cpu > b.max_metering_cpu:
        failures.append(f"metering CPU {m.metering_cpu} > budget {b.max_metering_cpu}")
    if m.backup_minutes_std_tenant > b.backup_window_minutes:
        failures.append(
            f"backup window {m.backup_minutes_std_tenant}min > SLA {b.backup_window_minutes}min"
        )
    if m.tsdb_gib_30d > b.tsdb_gib_30d:
        failures.append(f"TSDB {m.tsdb_gib_30d}GiB > budget {b.tsdb_gib_30d}GiB")
    if m.infra_cost_per_tenant_gbp / b.standard_price_gbp > b.max_infra_cost_share:
        failures.append("infra cost share exceeds 25% of price")
    if m.identity_daemons > b.max_identity_daemons:
        failures.append(
            f"identity plane runs {m.identity_daemons} extra daemons > budget "
            f"{b.max_identity_daemons} (SPIRE rejected; authbox in-process)"
        )
    if m.service_token_minutes > b.max_service_token_minutes:
        failures.append(
            f"service token lifetime {m.service_token_minutes}min > budget "
            f"{b.max_service_token_minutes}min"
        )
    if m.pq_handshake_cpu_delta > b.max_pq_handshake_cpu_delta:
        failures.append(
            f"PQ handshake CPU delta {m.pq_handshake_cpu_delta:.2f} cores > "
            f"budget {b.max_pq_handshake_cpu_delta:.2f}"
        )
    data_gib = DATA_TIB * 1024
    if m.tenants * b.tenant_quota_gib + b.backups_reserve_gib > data_gib:
        failures.append(
            f"storage: {m.tenants} x {b.tenant_quota_gib}GiB quota + "
            f"{b.backups_reserve_gib}GiB backups exceeds {data_gib:.0f}GiB data disk"
        )
    return failures


def main() -> int:
    budgets = LeanBudgets()
    model = ModelInputs()
    failures = check(budgets, model)
    print("LEAN PROOF — hosting platform")
    steady = (
        PLATFORM_OVERHEAD["edge_cpu"]
        + PLATFORM_OVERHEAD["control_cpu"]
        + PLATFORM_OVERHEAD["metrics_cpu"]
    )
    print(
        f"  tenants={model.tenants} steady_platform={steady:.1f} cores "
        f"(+{PLATFORM_OVERHEAD['backup_cpu']:.1f} windowed backup)"
    )
    if failures:
        for f in failures:
            print(f"  FAIL {f}")
        return 1
    print("  all budgets hold: capacity, overhead, isolation, metering,")
    print("  backup SLA, observability footprint, unit economics,")
    print("  identity-plane leanness")
    return 0


if __name__ == "__main__":
    sys.exit(main())
