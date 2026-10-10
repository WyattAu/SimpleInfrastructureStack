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
    "control_cpu": 0.5,     # hosting-api + dashboard
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
    metering_cpu: float = 0.02              # iter 3: cadvisor scrape pipeline
    backup_minutes_std_tenant: int = 12     # iter 4: restic incremental, warm cache; weekly prune+check scheduled inside the window budget
    tsdb_gib_30d: float = 4.0               # iter 6: prometheus 15s, 10 tenants
    infra_cost_per_tenant_gbp: float = 9.0  # iter 10: power+disk+B2 share


def check(b: LeanBudgets, m: ModelInputs) -> list[str]:
    """Return a list of failures; empty list = lean proof holds."""
    failures: list[str] = []

    platform_cpu = (
        PLATFORM_OVERHEAD["edge_cpu"]
        + PLATFORM_OVERHEAD["control_cpu"]
        + PLATFORM_OVERHEAD["metrics_cpu"]
        + PLATFORM_OVERHEAD["backup_cpu"]
    )
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
    return failures


def main() -> int:
    budgets = LeanBudgets()
    model = ModelInputs()
    failures = check(budgets, model)
    print("LEAN PROOF — hosting platform")
    print(f"  tenants={model.tenants} platform_cpu={sum(v for k, v in PLATFORM_OVERHEAD.items() if k.endswith('cpu')):.1f} cores")
    if failures:
        for f in failures:
            print(f"  FAIL {f}")
        return 1
    print("  all budgets hold: capacity, overhead, isolation, metering,")
    print("  backup SLA, observability footprint, unit economics")
    return 0


if __name__ == "__main__":
    sys.exit(main())
