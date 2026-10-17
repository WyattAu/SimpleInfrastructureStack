# Client-hosting platform — architecture and bare-metal runbook

The production home for customer tenants: a dedicated EPYC server at the
business premises, running Proxmox, hosting tenant Docker stacks with a
Caddy edge, restic+B2 backups and an independent watchdog.

Code layout:

| Path | What it is |
| --- | --- |
| `terraform/hosting/` | VM lifecycle on Proxmox (docker01) |
| `ansible/playbooks/hosting_bootstrap.yml` | host configuration (Docker, security, edge, timers) |
| `ansible/roles/hosting_docker_host/` | host baseline + backup/watchdog tooling |
| `ansible/roles/hosting_edge/` | Caddy edge with per-tenant routes |
| `ops/tenants/` + `ops/tenant-provision.sh` | per-tenant stacks and provisioning |
| `secrets/hosting.env.example` | secret template (SOPS) |

---

## Architecture decisions (and what was deliberately left out)

### One Docker VM, not a VM per tenant

docker01 runs every tenant stack, isolated by: separate Docker networks,
separate bind-mounted data trees under `/srv/tenants/<slug>`, resource
limits per service, and non-root users. Growth path — when a tenant needs
hard isolation or outgrows shared capacity, it gets its own VM (docker02)
created from the same Terraform; nothing about the tenant tooling changes
except `TENANT_ROOT`.

### No OPNsense VM for the pilot

An earlier sketch put an OPNsense firewall VM in front of everything. It
is left out on purpose: it is a third system to patch at 3am, and at pilot
scale the same boundaries are provided by the nftables input baseline,
Docker's per-publish firewall, and a separate internal bridge (vmbr1) that
tenant traffic cannot escape through. Revisit when there are multiple
hosts or contractual network-segmentation demands; the bridge layout
below already anticipates it.

### Caddy, not Traefik (for now)

Certificates per tenant domain with zero per-tenant config, one auditable
static file, no provider machinery. SIS's internal Traefik keeps doing its
internal job; the customer-facing edge is deliberately separate. `vane`
(the in-house Go gateway) is the intended long-term replacement — its
Caddyfile routes translate 1:1.

**Edge WAF research (loop iter 24):** the L7 inspection cutting edge is
OWASP Coraza (Go WAF library, ModSecurity Seclang-compatible, full CRS
support; the Caddy connector means a custom xcaddy-built edge binary) —
rejected as the DEFAULT: a custom edge build to answer unmeasured
attacks repeats the iter-2 Pingora mistake, CRS tuning is a per-tenant
false-positive treadmill, and body inspection costs edge CPU from the
0.5-core budget. The threat model says default-off: tenants are vetted
(tier 0), run upstream-maintained apps, and scanner/volumetric noise is
already handled by the CrowdSec estate (community blocklists via the
cf-workers bouncer). Adopted posture: CrowdSec IP reputation is the
default edge defense; Coraza+CRS is the OPT-IN tier (priced like the
gVisor tier) with triggers = a tenant demands WAF, a tenant app takes a
publicly-exploitable-class CVE, or `vane` (the in-house gateway, backlog
#8) reaches buildable state — Coraza-as-library is the natural embed for
vane, where a custom binary is already the plan.

**Edge TLS research (loop iter 12):** the cutting edge here is free, not
bought. (1) Post-quantum key agreement: X25519MLKEM768 (the hybrid
Cloudflare/Chrome standard; harvest-now-decrypt-later is the actual
threat) is enabled BY DEFAULT in Go 1.24+ crypto/tls - Caddy inherits it
with zero config, and ML-KEM-768 is generally FASTER than X25519
server-side (~45k ops/s vs ~19k; Cloudflare 2024 data). Post-quantum
CERTIFICATES are a different migration (WebPKI/HSM-bound, not before
~2026) and are the CA's problem, not the edge's - no action. Recorded
risk: the larger ClientHello breaks a thin tail of buggy middleboxes
(tldr.fail), but our path is direct 80/443 with no middleboxes. (2) ACME
profiles: Let's Encrypt now offers `classic` (90d default), `tlsserver`
(45d, leaner cert, CN/SKI/KU stripped) and `shortlived` (~6.7d, no
revocation machinery needed) via the ACME-profiles draft; CA/Baseline
Requirements cap certificate lifetimes at 47 days from March 2029, so
fully-automated renewal stops being optional industry-wide. Caddy already
renews with zero human involvement, which is exactly the posture the
short-lifetime world requires. Policy: stay on `classic` until Caddy
exposes profile selection on docker01, then move new routes to
`tlsserver`; `shortlived` is the opt-in tier for tenants who want
revocation-by-expiry.

 Pingora (Cloudflare's Rust proxy
framework) was evaluated and rejected for this platform's size: it is a
framework, not a proxy — no ACME wiring, no config surface, pre-1.0
without API stability — so adopting it means writing and maintaining a
custom edge to solve throughput problems that start north of ~50 busy
tenants. The aligned-future option is **River** (ISRG's batteries-on-top
proxy built on Pingora); revisit triggers: River 1.0, tenant count past
~50, or a routing need Caddy cannot express. Caddy stays: memory-safe,
single binary, ACME built-in, and its zero-downtime reload is now driven
by `ops/tenant-provision.sh` (idempotent route block + `caddy validate`
+ graceful reload), removing the manual onboarding step.

### Storage

Two ZFS pools on the node:

| Pool | Layout | Purpose |
| --- | --- | --- |
| `rpool` | 2× NVMe mirror | Proxmox OS, VM system disks |
| `tank` | 2× NVMe mirror (or RAIDZ1 HDD pair) | VM data disks, backups |

docker01 gets a data zvol from `tank` (scsi1), formatted ext4 and mounted
at `/srv`. Everything customer-owned lives under `/srv/tenants`; backups
under `/srv/backups` (restic local repo) with the B2 offsite copy.

Why ext4 on a zvol rather than ZFS inside the VM: snapshots and rollback
happen at the Proxmox layer for the whole disk, and the guest keeps a
boring, well-understood filesystem. No ZFS-in-KVM tuning rabbit holes.

**Storage research (loop iter 9):** the guest's gap was per-tenant disk
accounting - nothing stopped one tenant from filling `/srv` for everyone
(the storage noisy-neighbor). Fixed with **ext4 project quotas**
(`tune2fs -O project,quota`, `prjquota` mount, per-tenant project id +
hard limit set by `ops/tenant-provision.sh`, 100 GiB standard tier): the
spec's ext4 decision stands, and the enforcement is kernel-native with
zero new layers. ZFS datasets per tenant remain the growth path (quotas +
instant per-tenant snapshots as a paid feature) when tenants outgrow the
flat layout. On the node side, OpenZFS 2.3's fast dedup was evaluated for
`tank` and rejected: the restic repo already dedups, so kernel dedup would
pay RAM for deduplication we already have. Quota math is asserted in
`ops/lean-model.py` (10 x 100 GiB + 400 GiB backups = 1.4 TiB <= 1.5 TiB).

### Observability

Metrics, metering and alerting live on the TrueNAS Prometheus (scrapes
over vmbr1); the hosting VM runs no TSDB at all.

**Observability research (loop iter 13):** the compression frontier has
moved past Gorilla (what Prometheus TSDB implements): Chimp (VLDB'22)
halves the space of streaming XOR encoders, Elf (VLDB'24) improves
further via trailing-zero erasing at O(N)/O(1) cost. These are FORMAT
papers - adopting them means swapping the TSDB engine, and the wins
materialize at high cardinality that a 10-tenant fleet does not produce.
The lean move is the UPGRADE path, not the engine swap: Prometheus 3.0
(first major release in seven years) inherits years of measured TSDB
CPU/memory improvements, adds native OTLP ingest (the estate's
billing-kit metering is already OTLP-shaped) and Remote Write 2.0.
VictoriaMetrics stays deferred; the revisit trigger is now measured
cardinality pain on the TrueNAS Prometheus, not benchmark tables.
Upgrade policy: Prometheus 2.55 -> 3.x on TrueNAS with the migration
guide (rollback only to 2.55), 8 GiB TSDB budget unchanged.

**Metering research (loop iter 17):** Prometheus official guidance is
now "if you can, use native histograms" - one time series per histogram
(dynamic exponential buckets, ad-hoc quantiles, aggregatable) instead of
_sum/_count/one-series-per-bucket, with NHCB (native histograms with
custom buckets) ingesting classic histograms server-side when the
instrumentation library cannot emit them yet (Rust estate crates: watch
item for metrics-kit once OpenMetrics v2 text exposition lands). Policy:
enable native-histogram support on the TrueNAS Prometheus 3.x so estate
classic histograms (e.g. hosting_backup_duration_seconds) store as
single series - TSDB headroom for free, no app change. On pricing:
OpenCost/CNCF confirms allocation-based pricing is the industry default
precisely because usage memory is noisy; the platform's flat-tier +
RSS-usage add-on metering (iter 3) stands, with the recorded allocation
fallback unchanged if disputes arise.

### Network

```text
business router ── vmbr0 (mgmt/WAN, 192.168.0.0/24)
                       │
                       ├─ PVE host  (static, e.g. 192.168.0.50)
                       └─ docker01 NIC1 (DHCP or reserved)

vmbr1 (tenant bridge, 10.10.10.0/24, host = 10.10.10.1)
                       └─ docker01 NIC2 (10.10.10.10/24, no gateway)
```

- vmbr0: the only path to the internet and the LAN.
- vmbr1: internal traffic — future VM peers, backup staging, metrics.
  No gateway: docker01 cannot route to the internet via it and LAN hosts
  cannot reach tenants through it.
- Inbound public traffic terminates at docker01:80/443 only (Caddy).

**Network policy research (loop iter 18):** two verdicts. (1) nftables
flowtables (conntrack fastpath, software or NIC offload) rejected: an
offloaded flow bypasses per-packet forward-chain evaluation - the one
property a tenant fence must never lose (a rule change would not apply
to established flows until expiry), and the CPU saving is irrelevant at
a 0.5-core edge with 10 tenants. eBPF fastpaths (Cilium class) remain
rejected for the same reason. (2) The fence itself had a latent gap of
the iter-1/8 class: it was family `ip`, so IPv4-only - enabling Docker
IPv6 networking (daemon `ipv6: true`, auto-ULA fd00::/8 per Docker
docs) would have silently bypassed it for tenant v6 egress. The fence is
now family `inet`: tenant ULA sources cannot reach ULA/link-local v6
destinations (`hosting_docker_address_pools_v6`, default fd00::/8), the
rule is inert while no v6 networks exist, and v6 enablement can never
silently bypass it. Global-to-global tenant v6 egress stays open,
mirroring the v4 rule.

### DNS and certificate authorization

**DNS/revocation research (loop iter 25):** the Web PKI has left OCSP
behind - Let's Encrypt publishes revocation info as CRLs only (no OCSP
responder), so Caddy's OCSP stapling degrades to a harmless no-op on
our certs, and revocation strength now scales DOWN with certificate
lifetime (the iter-12 `shortlived` profile is the real revocation
story). The remaining DNS-side control is CAA (RFC 8659): policy -
(1) apex CAA `0 issue "letsencrypt.org"` on the registered domain and
on every customer domain at onboarding (cuts off every other public
CA's validation process); (2) strengthen with `;accounturi=<our ACME
account URL>` once the account exists, so a temporary domain hijack
WITHOUT our ACME account key cannot issue at all; (3) `validationmethods`
restriction considered and dropped - Caddy legitimately falls back
between http-01 and tls-alpn-01, and pinning the method trades real
renewal resilience for a marginal hardening. DNSSEC: optional at the
registrar, not a platform dependency (a SERVFAIL-ing DNSSEC setup can
BREAK ACME via CAA lookups - only enable it deliberately, then watch
dnsviz).

### Security model, in order


1. **nftables input baseline** on docker01: drop by default; SSH only from
   the mgmt LAN; 80/443 public; metrics scrapeable only from vmbr1.
2. **fail2ban** on SSH (nftables action).
3. **Cloud-init**: no password auth, admin key only.
4. **Tenants**: no-new-privileges, cap-drop ALL, non-root users, read-only
   rootfs where upstream allows (already enforced in `ops/tenants` templates).
5. **Isolation tiers** (research loop iter 1; see below): userns-remap +
   hardened defaults for the pilot, per-tenant rootless runtime as the
   growth target, gVisor as an opt-in sandbox, Firecracker reserved for a
   future untrusted-code tier.
6. **Secrets**: SOPS+age on the control node; decrypted onto the host at
   `/etc/sis-hosting/hosting.env` (0600) per run.
   **Secrets research (loop iter 5):** the pilot path leaves PLAINTEXT
   secrets at rest on the tenant-facing host - in isolation tier 0 a
   container escape that reads `/etc` owns every tenant. Evaluated: Vault
   and Infisical (both rejected: another service to run, patch and DR for
   one operator), systemd-creds + TPM2 (adopted as the target: `systemd-
   creds encrypt --with-key=tpm2` seals secrets to the VM's vTPM - PVE
   supports vTPM - and units decrypt into a tmpfs RuntimeDirectory at
   start; zero extra daemons). Implemented behind
   `hosting_secrets_tpm_creds` (default false until the DR rehearsal
   covers it); when enabled, plaintext never touches the host disk.
7. **Unattended-upgrades** for the security pocket-list.
   **Patching research (loop iter 19):** the cutting edge for container
   hosts is atomic A/B OS updating (systemd-sysupdate; the Fedora
   CoreOS/Flatcar/MicroOS class) and kernel livepatching (Ubuntu Pro) —
   both rejected for now: sysupdate needs a partition-based A/B image
   layout (the cloud-image VM is not A/B; rebuilding the image scheme
   for one VM is not lean), livepatch needs a distributor subscription
   and only defers the reboot, not removes it. The honest gap was
   silent kernel drift: unattended-upgrades INSTALLS kernels but only a
   reboot activates them, so "patched" could quietly mean "running
   code from 2024". The tenant watchdog now pages when the running
   kernel has been older than the newest installed one for >7 days
   (reboot window = tenants stop, backup, reboot, restore — rehearsed
   as the DR drill). systemd soft-reboot (v254+, userspace-only reset)
   noted as a future fast-path for userspace-only updates; revisit
   sysupdate when the estate ships its own image-based OS.
8. **Workload identity** (research loop iter 11): SPIFFE/SPIRE evaluated and
   rejected for the platform - SPIRE's distinguishing feature over plain
   OIDC identity providers is workload ATTESTATION (no static bootstrap
   credential), but it costs a stateful server plus a per-node agent, for
   a fleet that is one VM with a handful of estate services. On one host,
   placement IS attestation: loopback-only listeners + 0600
   systemd-credential files prove where a process runs. What we adopt is
   SPIFFE's *properties*, not its machinery: service-to-service auth uses
   short-lived tokens from authbox (15-minute access tokens for new
   estate services, auto-renewed via client_credentials; never long-lived
   static API keys), Keycloak keeps user-facing identity unchanged.
   Revisit triggers: a second hosting host (cross-node identity) or
   tenants needing to call estate services directly.
9. **Control-plane sandboxing** (research loop iter 15): Landlock (the
   kernel's unprivileged stackable LSM; ABI now covers filesystem
   hierarchies, TCP/UDP port rules, IPC scoping and audit logging) is
   exposed to unit files as `RestrictFileSystems=` since systemd 253.
   The estate's host units (hosting-api, dashboard, watchdog, backup
   sweep) carry a kernel-native fs-type deny list (nfs/cifs/fuse/sshfs)
   behind `hosting_unit_landlock_hardening` - an escape that reaches a
   networked or FUSE filesystem hits the LSM, not trust. Zero daemons,
   one config line per unit; gVisor/Kata stay in the isolation tiers as
   the VM-class options for TENANTS (tier 2/3) - Landlock is the
   control-plane's own cheap layer, not a tenant boundary.

### Isolation tiers (research loop iteration 1)

Research basis: gVisor architecture docs (userspace application kernel;
low fixed cost, high per-syscall cost — hostile to fsync-heavy databases)
and Firecracker (microVM: <125ms boot, <5 MiB overhead, hardware boundary,
requires KVM).

**Flaw found in the current spec.** Docker's `userns-remap` is
daemon-wide: every container on the host shares ONE mapped host UID
range. A container escape from tenant A lands as the same host user that
runs tenant B's containers. It namespaces against the *host*, not against
*other tenants*. Cross-tenant separation then rests entirely on nftables
rules and the absence of shared volumes — weaker than the spec claims.

**Tiered policy (adopted):**

| Tier | Runtime | Who | Overhead |
| --- | --- | --- | --- |
| 0 (pilot) | shared dockerd, daemon-wide userns-remap + seccomp default + cap-drop + no-new-privileges | vetted pilot tenants, no untrusted code | ~0-2% |
| 1 (growth target) | per-tenant **rootless runtime** — rootless dockerd or Podman (quadlet) per tenant, per-tenant subuid/subgid ranges | every tenant eventually | ~0-2%, one supervisor process set per tenant |
| 2 (opt-in) | gVisor `runsc` for syscall-light web apps that want sandboxing | premium option | 10-25% syscall-heavy |
| 3 (future) | Firecracker microVM per tenant | untrusted-code tier; needs bare-metal or nested-KVM host | ~5 MiB + guest kernel per tenant |

Tier 1 kills the aliasing flaw structurally: each tenant's containers map
to that tenant's own host UID range under its own rootless daemon, with
systemd user-slice cgroup delegation. It also removes the root daemon
from the container path. Migration is per-tenant and reversible
(`docker compose` files are OCI-compatible with Podman's compose
provider).

Hosting-api impact: it shells out to `docker compose`; tier 1 swaps that
for `DOCKER_HOST=unix:///run/user/<uid>/docker.sock` per tenant — the
API surface does not change.

**Resource-governance research (loop iter 16):** the cutting edge in CPU
scheduling is sched_ext (BPF-defined scheduler classes, mainline 6.12;
scx_flatcg implements hierarchical cgroup weight scheduling) — rejected:
documented ABI instability ("subject to change without warning between
kernel versions"), needs 6.12+ (past the spec's Ubuntu 24.04 base), and
the fair class already honors the cpu.weight shares iter 7 deployed; a
BPF scheduler solves desktop/gaming latency problems a 12-vCPU server
does not have. Revisit only if measured unfairness appears that PSI
cannot explain. The cutting edge that fits is the PSI supervision
protocol: systemd (254+) exposes per-service memory.pressure with
$MEMORY_PRESSURE_WATCH; kernel PSI itself is already the platform's
saturation guard (iter 7's node_pressure alert, now joined by a LOCAL
PSI check in the tenant watchdog — coarse memory-full/io-full/cpu-some
avg60 thresholds that fire even if the TrueNAS scrape path is dead).
Pressure-reactive cache trimming enters the estate-crate backlog
(shutdown-kit/worker-kit reading $MEMORY_PRESSURE_WATCH) rather than the
host: no unit change without an app that acts on the signal.
systemd-oomd/ManagedOOM rejected: docker hard limits + OOM killer
already bound the blast radius; another daemon is not lean.

### Image supply chain

Every tenant-facing image comes from the EvergreenImageRegistry (EIR,
our own GHCR namespace) - builds are scanned and attested in-repo;
upstream images are digest-pinned (renovate `pinDigests`, and
`versions.digests` for the estate).

**Supply-chain research (loop iter 21):** the enforcement frontier is
admission-control (sigstore policy controller, Connaisseur) - all
Kubernetes-bound; Docker has never shipped verify-on-pull (Docker
Content Trust/Notary v1 is deprecated), so compose-class hosts verify
nothing anywhere in the industry. Cosign verification itself is
mature: a signature binds the signer identity/key to the image digest,
verifiable with one command against any registry. The adopted model:
(1) the trust boundary is EIR ownership + digest pinning for upstream;
(2) `ops/tenant-provision.sh` carries a fail-closed cosign gate
(`TENANT_COSIGN_KEY`): when armed, every image in the rendered stack
must verify before a single byte is pulled - the one enforcement point
a non-Kubernetes host actually controls; (3) it is inert until EIR
signs its builds (backlog #12: cosign sign in the EIR build matrix),
which is the correct order - the consumer gate arrives before the
producer signature, so the first signed image is verified from birth.

### Backups and recovery

- Per tenant: `ops/tenant-backup.sh` — restic snapshot tagged
  `tenant:<slug>` into `/srv/backups/restic`, copied offsite to B2.
- **Backup research (loop iter 14):** the CDC research frontier (fresh
  ICDE'27 benchmark arXiv:2610.13704; VectorCDC FAST'25/ACM-TOSS follow-up
  arXiv:2508.05797) confirms AE-class chunkers as most balanced and SIMD
  vectorization as an 8-26x chunking-throughput win - but chunking
  throughput is NOT our bottleneck (iter 4: 12 min vs 30 min SLA), and the
  same benchmark lineage exposed a longstanding AE parameterization error
  reproduced across papers and tools: a caution against adopting research
  chunker defaults. Chunker swap stays rejected. The 2025 chunking-attack
  paper (arXiv:2504.02095, Alexeev/Percival/Zhang) is the finding that
  DOES apply: content-defined chunking + cross-file dedup creates
  confirmation side channels (an attacker who can query dedup behaviour
  can test whether a target file exists in a backup). Our exposure: the
  restic repo dedups across tenants by design (storage win) and the
  repo-side chunker polynomial is per-repo random; exploitation requires
  repo-oracle access, which means operator-tier credentials
  (RESTIC_PASSWORD on docker01 - the same exposure systemd-creds TPM2
  closes). Recorded: single shared repo stands; no tenant ever gets
  repo-adjacent access; the side-channel property is documented so a
  future "tenants browse their own backups" feature knows it must move to
  per-tenant repos first.
- **Backup research (loop iter 4):** restic's Rabin chunking vs
  kopia's FastCDC-class chunking was evaluated — switching tools buys
  nothing here: measured
  backups run ~12 min against a 30-min SLA budget and dedup is not the
  bottleneck. The real gaps were operational and are now fixed in the
  nightly sweep: retention is **enforced weekly** (was opt-in via
  `TENANT_PRUNE` and effectively never ran) and **`restic check
  --read-data-subset=25%` runs weekly** (rolling monthly full coverage)
  with a ntfy page on failure. Customers are told in the service
  catalogue that the consistent snapshot window is nightly ~03:30 and
  lasts minutes (stack stopped for the copy, then restarted).
- Nightly sweep (`sis-hosting-tenant-backup.timer`, 03:30) with ntfy alert
  on any tenant failure; watchdog (`sis-hosting-watchdog.timer`, 15 min)
  alerts on unhealthy containers, dead edge, or stale offsite (>25h).
  **Dead-man research (loop iter 23):** a watchdog on the host it
  watches cannot report the host's own death - silence is ambiguous
  (healthy vs dead). The healthchecks.io model (expect a ping, page on
  its ABSENCE after grace) closes this: docker01's watchdog heartbeats
  `hosting.watchdog.*` to eventbusd every 15 minutes, and the CachyOS
  meta-watchdog - which runs on different silicon entirely - pages if
  the last beat is >2700s old (two missed beats + slack), if the
  heartbeat has never existed, or if the eventbusd query itself is
  unreadable. Arming requires `hosting_eventbus_url`/`token` wired into
  the docker01 role (the heartbeat publisher).
- **Restore drills are code (loop iter 26):** "rehearse this before the
  first paying customer" was a wish nobody could schedule - so the sweep
  does it. First Sunday of each month, one tenant's latest snapshot is
  actually restored to a scratch tree (`restic restore latest --tag
  tenant:<slug>`) and proven (files exist, compose file came back), then
  deleted; rotation is deterministic per month so every tenant gets a
  full-restore proof over time, the drill runs inside the yielding sweep
  unit, and a failed drill pages with RESTORE DRILL FAILED. Verified
  restores, not just verified repositories (iter 4's `restic check`
  proves the repo; this proves the customer artifact).
- **Node loss** = reinstall Proxmox per this runbook, `terraform apply`,
  `ansible-playbook hosting_bootstrap.yml`, `restic restore` per tenant.
  Rehearse this before the first paying customer (see checklist).

### Deploy pipeline

Pushes to this repo deploy to TrueNAS (Forgejo mirror -> checkout ->
deploy webhook -> `deploy.sh`: flock, `git reset --hard`, ansible
playbook) with the Rust twin (`deploy-webhook-rs`) flag-gated beside it:
both receive every event under a shared flock, the twin verifies-only at
0%, full cutover is one flagsd call, and every decision publishes to
eventbusd for diff/replay.

**Deploy/webhook research (loop iter 20):** the GitOps engines (Flux,
Argo) are K8s reconcilers — rejected: our convergence target is compose +
ansible on one host, not a cluster API. Kamal-class tools ship APP
artifacts over SSH — rejected for infra convergence, noted for future
tenant-app deploys. The cutting edge that fits is the **Standard
Webhooks** spec (v1.0: `webhook-id`/`webhook-timestamp`/`webhook-signature`
headers, `v1` HMAC-SHA256 + `v1a` ed25519, space-delimited multi-signature
for zero-downtime key rotation, idempotency via `webhook-id`, 2xx =
success / 410 disables endpoint, exponential-backoff retry schedules
spanning days with jitter, 15-30s consumer timeouts, SSRF proxy
guidance). Policy: inbound GitHub deploy events keep `X-Hub-Signature-256`
(interop constraint; Standard Webhooks explicitly supports side-by-side
legacy schemes); OUTBOUND estate webhooks (webhookkit senders, eventbusd
consumers) adopt Standard Webhooks v1 signatures + idempotency keys —
recorded as the webhookkit crate enhancement. Internal deploy webhooks
keep fast-fail retries (4x/30s) because eventbusd holds durability; the
days-long backoff schedules apply to customer-facing senders when the
estate grows them.

### Config drift

**Drift research (loop iter 22):** the OpenGitOps principles v1.0
(declarative, versioned+immutable, pulled, CONTINUOUSLY RECONCILED)
name the property the legacy deploy path lacked: reconciliation. Our
deploy is a force-sync (`git reset --hard` + compose/ansible), which
makes drift SILENT by construction — the Oct-11 incident was exactly
this class (live hotfixes in the checkout that the next deploy would
wipe; a hand-edited appdata dynamic.yml diverging from the tracked
copy). K8s reconcilers solve this with agents diffing desired vs
actual; the lean equivalent is two checks at the force-sync boundary:
the meta-watchdog now reports uncommitted/ahead state on the TrueNAS
checkout (any drift pages, because a force-sync WILL destroy it), and
the deploy pipeline syncs `stacks/proxy/config/dynamic.yml` into
appdata (traefik's watched file provider picks it up live) — the repo
copy is canonical, hand-edits to the live file get overwritten with a
diff on next deploy instead of silently diverging.

---

## Bare-metal runbook (order matters)

### 0. Before the server arrives

- [ ] Business broadband installed, **static IP or DHCP reservation**
      confirmed NOT CGNAT (test: router WAN IP == what `curl ifconfig.me`
      returns from inside the LAN)
- [ ] Ports 80/443 reachable from outside (test with a laptop hotspot)
- [ ] Companies House, ICO registration, insurance done (see service catalogue)
- [ ] `secrets/hosting.env.encrypted` created and its `RESTIC_PASSWORD`
      recorded in the password manager **and** on paper in the safe
- [ ] CAA record on the registered domain: `0 issue "letsencrypt.org"`
      (iter 25; add `;accounturi=<ACME account URL>` once the account
      exists — pin issuance to our account so a domain hijack alone
      cannot mint certificates). Every customer domain gets the same at
      onboarding.

### 1. BIOS/firmware

- Enable: SR-IOV/ACS off is fine, but enable **IOMMU** (AMD-Vi) and AES-NI
- ECC reporting visible in BMC/IMPI
- Boot order: NVMe first
- Set a BIOS password; note the BMC address and change its default creds

### 2. Proxmox VE install

- Install PVE 9.x onto the intended root NVMe pair as **ZFS RAID1**
  (installer: "ZFS (RAID1)", 4–8GB ARC max will be tuned later)
- Hostname: `hosting01` (matches `pve_node` default in Terraform)
- Static IP on the business LAN, e.g. `192.168.0.50/24`, gateway = router
- Post-install:

  ```bash
  # No-subscription repo + updates
  sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
  sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/ceph.list  # if present
  apt update && apt full-upgrade -y
  # ARC capped so the VM gets its RAM
  echo "options zfs zfs_arc_max=8589934592" > /etc/modprobe.d/zfs.conf
  update-initramfs -u -k all
  ```

### 3. ZFS data pool + bridges

```bash
# Data pool from the second NVMe pair (adjust device names!)
zpool create -o ashift=12 tank mirror /dev/nvme1n1 /dev/nvme2n1
zfs set compression=zstd atime=off tank
zfs create tank/vm-disks

# Internal tenant bridge (vmbr1). vmbr0 already exists from the installer.
cat >> /etc/network/interfaces <<'EOF'

auto vmbr1
iface vmbr1 inet static
    address 10.10.10.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # NAT for VM default routes if ever needed (disabled by design now)
EOF
ifreload -a
```

### 4. Ubuntu cloud-image template (once)

```bash
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img

qm create 9000 --name ubuntu-2404-template --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0 --agent enabled=1 \
  --serial0 socket --vga serial0
qm importdisk 9000 ubuntu-24.04-server-cloudimg-amd64.img tank
qm set 9000 --scsihw virtio-scsi-pci \
  --scsi0 tank:vm-9000-disk-0,discard=on,ssd=1 \
  --ide2 local:cloudinit --boot order=scsi0
qm template 9000
```

### 5. Terraform

```bash
export TF_VAR_pve_endpoint="https://192.168.0.50:8006/"
export TF_VAR_pve_api_token="root@pam!terraform=<token>"   # create in PVE UI
#   PVE UI → Datacenter → Permissions → API Tokens (no privilege separation,
#   or grant the token Administrator on the hosting pool)
export TF_VAR_ssh_admin_keys='["ssh-ed25519 AAAA... your key"]'

cd terraform/hosting
terraform init
terraform plan     # read it. every time. human-gated applies.
terraform apply
```

`terraform output` prints the SSH target (`wyatt@10.10.10.10`, via
ProxyJump through the node). Set `hosting_pve_jump_host` in
`ansible/group_vars/hosting.yml` to the node's real IP first.

### 6. Ansible bootstrap

```bash
ls -l /dev/disk/by-id/        # on the PVE host: find drive-scsi1's by-id
# put that value in ansible/group_vars/hosting.yml → hosting_data_disk_by_id

cd ansible
ansible-playbook -i inventory/hosts.yml playbooks/hosting_bootstrap.yml
```

The playbook refuses to run against anything but `docker01`.

### 7. Smoke checklist (gate before the first tenant)

- [ ] `qm guest cmd 110 ping` answers on the PVE host
- [ ] From the workstation: `ssh -J <pve> wyatt@10.10.10.10` works, no password
- [ ] `nft list ruleset` shows the baseline; `nmap` from outside shows **only** 80,443
- [ ] `fail2ban-client status sshd` answers
- [ ] `/srv` mounted (`findmnt /srv`), restic repo initialised:
      `RESTIC_REPOSITORY=/srv/backups/restic RESTIC_PASSWORD_FILE=/etc/sis-hosting/restic-password restic init`
- [ ] Watchdog timer ran clean: `journalctl -u sis-hosting-watchdog -n 5`
- [ ] Caddy serving: `curl -I http://<public-ip>` (ACME works once DNS exists)

### 8. First tenant

```bash
# on docker01
TENANT_ROOT=/srv/tenants /opt/sis-hosting/bin/tenant-provision.sh \
  acme documents --domain docs.acme.example
# DNS: A record for docs.acme.example → the static public IP
# add the tenant to hosting_tenants (ansible/group_vars/hosting.yml), then:
ansible-playbook -i inventory/hosts.yml playbooks/hosting_bootstrap.yml --tags edge
```

Then follow `.docs/tenant-onboarding.md`.

---

## Disaster recovery drill (do this quarterly)

1. `terraform destroy` is **not** part of the drill — do not nuke production.
   Instead: restore drill per tenant (`tenant-backup.sh --restore`) on a
   scratch VM.
2. Annually (or before a node migration): full rebuild in a maintenance
   window — new VM from Terraform, bootstrap, restore all tenants from B2,
   compare against the live host, then cut over.
3. Keep the drill notes in `.docs/` — an unrehearsed runbook is a wish,
   not a plan.
