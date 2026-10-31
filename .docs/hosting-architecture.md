# Client-hosting platform: architecture and bare-metal runbook
limits per service, and non-root users. Growth path; when a tenant needs
(the in-house Rust edge gateway; thread-per-core, io_uring, GCRA filter
support; the Caddy connector means a custom xcaddy-built edge binary) -
#8) reaches buildable state: Coraza-as-library is the natural embed for
framework, not a proxy; no ACME wiring, no config surface, pre-1.0
without API stability; so adopting it means writing and maintaining a
- vmbr1: internal traffic; future VM peers, backup staging, metrics.
IPv4-literal clients suffer; AAAA presence is quietly becoming a
   CoreOS/Flatcar/MicroOS class) and kernel livepatching (Ubuntu Pro) -
   (reboot window = tenants stop, backup, reboot, restore; rehearsed
low fixed cost, high per-syscall cost; hostile to fsync-heavy databases)
rules and the absence of shared volumes; weaker than the spec claims.
| 1 (growth target) | per-tenant **rootless runtime**; rootless dockerd or Podman (quadlet) per tenant, per-tenant subuid/subgid ranges | every tenant eventually | ~0-2%, one supervisor process set per tenant |
for `DOCKER_HOST=unix:///run/user/<uid>/docker.sock` per tenant; the
scx_flatcg implements hierarchical cgroup weight scheduling); rejected:
PSI check in the tenant watchdog; coarse memory-full/io-full/cpu-some
- Per tenant: `ops/tenant-backup.sh`; restic snapshot tagged
  kopia's FastCDC-class chunking was evaluated; switching tools buys
Argo) are K8s reconcilers; rejected: our convergence target is compose +
artifacts over SSH; rejected for infra convergence, noted for future
consumers) adopt Standard Webhooks v1 signatures + idempotency keys -
makes drift SILENT by construction; the Oct-11 incident was exactly
appdata (traefik's watched file provider picks it up live); the repo
      (iter 37: AAAA readiness; Caddy/fence/input-chain are already
      exists; pin issuance to our account so a domain hijack alone
- [ ] Processor DPA template drafted (iter 33; UK GDPR Art 28); signed
- **NUT master** (iter 34); the PVE host owns the UPS cable and serves
- **Authenticated time (NTS)** (iter 45); everything downstream trusts
1. `terraform destroy` is **not** part of the drill; do not nuke production.
   window; new VM from Terraform, bootstrap, restore all tenants from B2,
3. Keep the drill notes in `.docs/`; an unrehearsed runbook is a wish,