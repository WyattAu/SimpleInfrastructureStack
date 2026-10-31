# Client-hosting platform: architecture and bare-metal runbook

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
separate bind-mounted data trees under `/srv/tenants`, resource
limits per service, and non-root users. Growth path; when a tenant needs
hard isolation or outgrows shared capacity, it gets its own VM (docker02)
created from the same Terraform; nothing about the tenant tooling changes
except `TENANT_ROOT`.

**Staging research (loop iter 36):** the platform has no staging - every
deploy is a force-sync to the one production host, gated only by
validation. App-deploy tooling with first-class staging destinations
validates the shape, and the pieces already exist here: docker02 from
the same Terraform module, a second inventory group, and flagsd - the
cutover control plane - gating which destination receives a deploy.
Adopted role for docker02 when the EPYC node arrives: STAGING, not a
second production (config validation, tenant-onboarding dry runs, the
DR-rehearsal restore target, tier-1 rootless spikes) - deliberately
NOT performance testing. Capacity honesty: a staging VM is a
0.5-vCPU/2-GiB line item INSIDE the lean model's capacity check
(staging_cpu, currently 0 until the host exists) - at full build-out
10 tenants + platform + staging lands exactly at the 12-vCPU ceiling,
so staging and the tenth revenue tenant coexist only because the
backup window borrows compressible headroom; growth past ten tenants
means a second production node, which is the documented growth path
anyway.

**Capacity exit triggers (loop iter 47):** the lean model is static;
these measured conditions are what override it, and every sensor they
need already exists. T1 - demand: a signed tenth tenant starts
PROCUREMENT of the second production node (lead time must not be the
capacity plan). T2 - saturation: 30-day sustained node_pressure cpu
"some" avg60 > 20% OUTSIDE the backup window (the yield design
tolerates windowed saturation by design; sustained pressure outside it
is real demand, and the iter-16 watchdog + TrueNAS PSI alerts are the
sensors). T3 - memory: platform+tenant RSS sustained > 70% of 96 GiB
(cAdvisor gauges; memory is NOT the binding constraint at ten tenants
- CPU is). T4 - storage: recurring 85% watchdog pages on the data disk
(iter 43) = zvol growth on tank, before any second node. Any trigger
fires a capacity review against the lean model with MEASURED inputs
replacing the estimates - the model's numbers are hypotheses the fleet
tests, per the loop contract.


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
(the in-house Rust edge gateway; thread-per-core, io_uring, GCRA filter
reusing the estate's own throttle-kit, zero-loss hot upgrade) is the
intended long-term replacement; the migration story is per-route, not
Caddyfile-translation as first assumed.

**Edge WAF research (loop iter 24):** the L7 inspection cutting edge is
OWASP Coraza (Go WAF library, ModSecurity Seclang-compatible, full CRS
support; the Caddy connector means a custom xcaddy-built edge binary) -
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
#8) reaches buildable state: Coraza-as-library is the natural embed for
vane, where a custom binary is already the plan.

**Rate-limit research (loop iter 27):** the platform's rate limiting is
a three-layer stack, and research says it is the right shape. (1)
Flood/scanner abuse: CrowdSec IP reputation (iter 24). (2)
Tenant-vs-tenant fairness: cgroup cpu_shares (iter 7). (3) API fairness:
GCRA in-process via throttle-kit (the same single-state
theoretical-arrival-time algorithm Stripe/Heroku run; smooth pacing, no
background drip process, O(1) state per key). caddy-ratelimit (mholt)
was evaluated for an edge layer: it needs a custom xcaddy build (the
iter-2/24 objection again), holds O(Kn) ring-buffer memory in the
proxy, and its distributed mode is approximate - rejected at this
scale. One recorded lesson for any FUTURE edge limiter (vane): per-IP
keys are porous under IPv6 (one /64 = effectively unlimited keys), so
edge limiting must group by ipv4/ipv6 network prefix - caddy-ratelimit's
ipv6_prefix option is the pattern to copy. Revisit trigger: measured
abuse that reputation + cgroups cannot contain.

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

**Edge headers (loop iter 48):** audited against the OWASP Secure
Headers Project: the per-tenant origin block already sets the
UNIVERSAL subset - HSTS (max-age 1y, deliberately WITHOUT
includeSubDomains: customers may run subdomains of their domain that
this edge does not serve), nosniff, Referrer-Policy
strict-origin-when-cross-origin, and Server suppression. Everything
else on the OSHP list is APP territory and stays there: CSP differs
per tenant app (ferro carries its own), X-Frame-Options/frame-ancestors
would break tenants that legitimately embed, and Cross-Origin-Opener-
Policy can break OAuth popup flows (Keycloak). X-XSS-Protection is
correctly absent (removed by browsers). The gap was verification, not
configuration: the smoke checklist now asserts the headers on a live
origin, so a Caddyfile regression cannot silently strip them.

**Edge research (loop iter 2):** Pingora (Cloudflare's Rust proxy
framework) was evaluated and rejected for this platform's size: it is a
framework, not a proxy; no ACME wiring, no config surface, pre-1.0
without API stability; so adopting it means writing and maintaining a
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

**Snapshot-tier research (loop iter 29):** the growth path's engine
choice, made before it is needed. zrepl (Go, 0.7.0) is a one-stop
replication DAEMON: pull/push transports (TCP+TLS/SSH), resumable
send/recv, bookmarks, pre/post-snapshot hooks with MySQL/Postgres
builtins, Prometheus endpoint - rejected for this tier: its transport
layer duplicates the job restic+B2 already owns (offsite), and a
permanent daemon buys nothing for local snapshots. sanoid's shape
(timers + a config file; syncoid as a separate invoked script) is the
lean fit for the PVE node. Policy recorded now so the paid tier is
priced honestly later: per-tenant ZFS datasets on `tank` +
sanoid-class timer snapshots (frequent/ hourly/ daily fading) give
instant per-tenant rollback ("oops" recovery) and drop effective RPO
from 24h to ~15min; SNAPSHOTS ARE NOT BACKUPS - same-pool copies never
count toward the durability promise, restic+B2 stays the only offsite
and DR artifact, and the iter-26 restore drill remains the proof of
recoverability.

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
- vmbr1: internal traffic; future VM peers, backup staging, metrics.
  No gateway: docker01 cannot route to the internet via it and LAN hosts
  cannot reach tenants through it.
- Inbound public traffic terminates at docker01:80/443 only (Caddy).

**Edge IPv6 readiness (loop iter 37):** the IETF v6ops 6mops draft
(IPv6-mostly networks, v10 Sept 2026) documents where clients are
going: mobile carriers run v6-only with NAT64/464XLAT today and
enterprise/public Wi-Fi is migrating the same way (DHCPv4 Option 108
withholding v4 from v6-capable devices). An A-ONLY site remains
reachable through NAT64+DNS64, but DNS64 is DNSSEC-incompatible and
IPv4-literal clients suffer; AAAA presence is quietly becoming a
reachability QUALITY issue, not a nicety. The platform's posture is
"ready by configuration, nothing to build": Caddy serves dual-stack
with no config; the nftables baseline is family `inet` (ICMPv6 + 80/443
open; SSH deliberately stays v4 mgmt-only); the tenant fence covers
Docker v6 egress (iter 18). The single gate is the ISP: the §0
checklist now asks for prefix delegation alongside the CGNAT check.
Policy: when PD exists, add AAAA records at onboarding, verify inbound
v6 with the same smoke tests, and re-check the metering/ACL surfaces
that key on client IPs (CrowdSec lists, GCRA keys are v6-aware already).

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
   **Cloud credential scoping (iter 49):** runtime B2 credentials are
   STANDARD application keys - single bucket, `tenants/` file-name
   prefix, minimal capabilities (delete retained only because the
   weekly retention IS the policy; the iter-38 append-only second
   offsite is the deletion counterweight) - and the account master key
   never appears in SOPS or any env file; each additional consumer gets
   its own prefix-scoped key, so one leaked runtime key cannot reach
   another consumer's objects.
   **Rotation runbook (loop iter 28):** every secret is encrypted to
   TWO age identities (admin + recovery, one sops key_group - any one
   member can decrypt), so rotation is a zero-downtime, no-risk
   operation: generate a replacement identity, add it to `.sops.yaml`,
   `sops updatekeys secrets/*.env.encrypted` (re-wraps each file's data
   key to the current recipients; sops 3.13+), verify a decrypt with
   the NEW identity, then securely delete the retired identity file -
   the recovery identity bridges the whole window. `sops --rotate`
   additionally re-keys each file's data key (annual hygiene; content
   untouched). Triggers: control-node identity compromise (immediate),
   key-material changes, or annually alongside the DR rehearsal. The
   TPM2-creds path re-seals from plaintext at every bootstrap and needs
   no rotation itself.
7. **Unattended-upgrades** for the security pocket-list.
   **Patching research (loop iter 19):** the cutting edge for container
   hosts is atomic A/B OS updating (systemd-sysupdate; the Fedora
   CoreOS/Flatcar/MicroOS class) and kernel livepatching (Ubuntu Pro) -
   both rejected for now: sysupdate needs a partition-based A/B image
   layout (the cloud-image VM is not A/B; rebuilding the image scheme
   for one VM is not lean), livepatch needs a distributor subscription
   and only defers the reboot, not removes it. The honest gap was
   silent kernel drift: unattended-upgrades INSTALLS kernels but only a
   reboot activates them, so "patched" could quietly mean "running
   code from 2024". The tenant watchdog now pages when the running
   kernel has been older than the newest installed one for >7 days
   (reboot window = tenants stop, backup, reboot, restore; rehearsed
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

### Data governance

UK GDPR duties the platform already carries structurally, now written
down (ICO security guidance: "Personal data breaches: a guide" +
encryption guidance; UK GDPR arts. 5(1)(e), 28, 32-34):

- **Roles**: for TENANT CONTENT the platform is a processor - a
  signed data-processing agreement (Art 28) is a prerequisite for the
  first customer, alongside the ICO registration already on the
  checklist. For OPERATIONAL data (billing, auth/decision logs,
  contacts) the platform is its own controller; the customer-facing
  privacy notice covers that.
- **Retention schedule** (storage limitation, Art 5(1)(e)) - mapped to
  the machinery that already enforces it, not aspirational:

  | Data | Retention | Enforced by |
  | --- | --- | --- |
  | Tenant content | contract term + 30d grace, then erased (deprovision receipt = the erasure artifact) | `tenant-lifecycle.sh` (iter 10) |
  | Tenant data inside backups | expires on the 7d/5w/12m schedule - erasure completes when the last snapshot containing it ages out; the receipt records that date | weekly forget/prune (iter 4) |
  | Access/decision audit log | 12 months (security purpose) | authbox tamper-audit |
  | Deploy/watchdog events | 90 days | eventbusd replay window |
  | Metrics | 30 days | TrueNAS Prometheus retention |

- **Breach runbook** (Art 33/34): detection rides the existing
  watchdogs and incident docs; on a personal-data breach, notify the
  ICO within 72h of awareness where it risks rights and freedoms, and
  affected tenants without undue delay where risk is high. The
  incident doc gains a breach section at next use - no new
  infrastructure.
- **Security-of-processing** (Art 32) is the platform's existing
  control set read through the regulation: restic client-side
  encryption, the TPM2-creds path (iter 5), TLS at the edge (iter 12),
  the tenant fence (iter 8/18), and tamper-evident audit logging.

### Isolation tiers (research loop iteration 1)

Research basis: gVisor architecture docs (userspace application kernel;
low fixed cost, high per-syscall cost; hostile to fsync-heavy databases)
and Firecracker (microVM: <125ms boot, <5 MiB overhead, hardware boundary,
requires KVM).

**Flaw found in the current spec.** Docker's `userns-remap` is
daemon-wide: every container on the host shares ONE mapped host UID
range. A container escape from tenant A lands as the same host user that
runs tenant B's containers. It namespaces against the *host*, not against
*other tenants*. Cross-tenant separation then rests entirely on nftables
rules and the absence of shared volumes; weaker than the spec claims.

**Tiered policy (adopted):**

| Tier | Runtime | Who | Overhead |
| --- | --- | --- | --- |
| 0 (pilot) | shared dockerd, daemon-wide userns-remap + seccomp default + cap-drop + no-new-privileges | vetted pilot tenants, no untrusted code | ~0-2% |
| 1 (growth target) | per-tenant **rootless runtime**; rootless dockerd or Podman (quadlet) per tenant, per-tenant subuid/subgid ranges | every tenant eventually | ~0-2%, one supervisor process set per tenant |
| 2 (opt-in) | gVisor `runsc` for syscall-light web apps that want sandboxing | premium option | 10-25% syscall-heavy |
| 3 (future) | Firecracker microVM per tenant | untrusted-code tier; needs bare-metal or nested-KVM host | ~5 MiB + guest kernel per tenant |

Tier 1 kills the aliasing flaw structurally: each tenant's containers map
to that tenant's own host UID range under its own rootless daemon, with
systemd user-slice cgroup delegation. It also removes the root daemon
from the container path. Migration is per-tenant and reversible
(`docker compose` files are OCI-compatible with Podman's compose
provider).

Hosting-api impact: it shells out to `docker compose`; tier 1 swaps that
for `DOCKER_HOST=unix:///run/user/<uid>/docker.sock` per tenant; the
API surface does not change.

**Resource-governance research (loop iter 16):** the cutting edge in CPU
scheduling is sched_ext (BPF-defined scheduler classes, mainline 6.12;
scx_flatcg implements hierarchical cgroup weight scheduling); rejected:
documented ABI instability ("subject to change without warning between
kernel versions"), needs 6.12+ (past the spec's Ubuntu 24.04 base), and
the fair class already honors the cpu.weight shares iter 7 deployed; a
BPF scheduler solves desktop/gaming latency problems a 12-vCPU server
does not have. Revisit only if measured unfairness appears that PSI
cannot explain. The cutting edge that fits is the PSI supervision
protocol: systemd (254+) exposes per-service memory.pressure with
$MEMORY_PRESSURE_WATCH; kernel PSI itself is already the platform's
saturation guard (iter 7's node_pressure alert, now joined by a LOCAL
PSI check in the tenant watchdog; coarse memory-full/io-full/cpu-some
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

**Daemon hardening research (loop iter 31):** two daemon-wide additions
adopted: `no-new-privileges: true` (setuid/sgid escalation blocked by
default in EVERY container - per-service compose settings still win, so
this only catches whatever forgets to set it) and `live-restore: true`
(dockerd restarts and patch upgrades stop being a tenant outage; per
Docker docs: patch releases only, no swarm here, long daemon downtime
can fill the 64K FIFO log buffer). Two classic hardening flags
explicitly REJECTED with reasons: `icc: false` (kills intra-compose
traffic - every tenant app talks service-to-service) and
`userland-proxy: false` (loopback-only publishes - 127.0.0.1:port,
which many stacks use - stop working without it). THE REAL CATCH was
not a flag: render-validation of the daemon.json template exposed a
string-concatenation bug that produced INVALID JSON (`],` + `,"userns-
remap"` = double comma) - the first docker01 bootstrap would have
failed dockerd at the EPYC rehearsal. The config is now built as a
dict and serialized with to_nice_json, render-tested in both remap
modes.

**Tier-1 refresh (loop iter 35):** the growth target is now a concrete
design, validated against current Podman (5.x). Each tenant gets its
own host user with a DEDICATED subuid/subgid range plus a systemd user
session (`loginctl enable-linger`) running `podman.socket`; stacks are
quadlets or `docker compose` against that user's socket
(`DOCKER_HOST=unix:///run/user/<uid>/podman/podman.sock` - the hosting-
api swap designed in iter 1, unchanged). Podman 5's default rootless
networking is pasta (passt), which replaced slirp4netns; loopback-only
port publishes - the platform's edge pattern - work natively. Quadlet
puts tenant services under systemd USER units, which plugs into the
iter-7 cgroup weight governance and journald logging directly. What
tier-1 buys remains the iter-1 fix: per-tenant UID ranges end the
userns-remap aliasing, and no root daemon sits in the container path.
The COST the tier table under-recorded: METERING - cAdvisor's
container discovery (iters 3/17) does not see rootless containers the
same way under user-slice cgroup nesting; tier-1 migration therefore
carries a metering work item (per-slice accounting via systemd
exporter or cAdvisor cgroup driver changes) and the RSS meter must be
re-validated before any tenant moves. Migration trigger unchanged: the
first tenant that needs real cross-tenant containment, spiked first on
a scratch VM (backlog #7).

**Tier-3 refresh (loop iter 44):** Firecracker is alive and hardening
in exactly the direction multi-tenancy needs - v1.17.0 (Sept 2026)
ships PCI device hotplug (developer preview), virtio-mem hotplug,
bzImage guest boot, 6.18 guest-kernel support, VMClock snapshot
safety, and T2S-class CPU templates that clear side-channel bits
(FB_CLEAR); the virtio PCI transport CVE-2026-5747 was patched across
four release branches within days of disclosure. The NSDI'20 paper's
headline numbers stand (Lambda/Fargate production, millions of
workloads; ~5 MiB VMM overhead, ~125 ms boot). What the refresh adds
to the tier's design: (1) snapshot/restore becomes the tenant
cold-start mechanism (boot-from-snapshot in milliseconds - the Fly.io
pattern); (2) virtio-mem/balloon enables resizing a tenant without
reboot; (3) the jailer (chroot + seccomp + namespaces) remains the
wrapping boundary. One honest restatement: a microVM tenant is a VM
BOUNDARY, not compose tenancy - tier-3 serves the untrusted-code tier
as live single-purpose environments, and compose-based tenants would
need a guest runtime inside (docker-in-microVM), which changes the
management shape. The spike (backlog #7) now has concrete targets:
jailer-sealed microVM, snapshot-restore boot, nested-KVM check on the
EPYC, and a metering story (microVMs report their own memory/cpu via
virtio-balloon, sidestepping the tier-1 cAdvisor problem).

### Backups and recovery


- Per tenant: `ops/tenant-backup.sh`; restic snapshot tagged
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
  kopia's FastCDC-class chunking was evaluated; switching tools buys
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
  the docker01 role (the heartbeat publisher). **External vantage
  (iter 41):** every monitor above still runs INSIDE the network - an
  ISP or router failure silences the monitors along with the service.
  The `external-probe` GitHub Actions workflow (every 15 min, offset
  from the internal watchdog) probes the public edge from GitHub's
  network and pages ntfy - reachable externally - only on CONFIRMED
  failure (3 attempts over ~90s; the tunnel has a real blip history).
  Silence of the probe itself (GitHub outage) is tolerable: the
  internal watchdogs still cover the inside. Arming: `NTFY_PROBE_URL`
  repository secret; unset = log-only mode, visible in run history.
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
- **PITR tier research (loop iter 32):** the default backup is nightly
  stop-the-stack restic - RPO 24h, consistency proven by the
  restart-healthy gate, window budgeted, recoverability proven by the
  iter-26 drill. For tenants whose CONTRACT demands RPO << 24h, the
  growth tier is continuous WAL archiving, and the engine is
  **pgBackRest** (2.60, a PostgreSQL Global Development Group project):
  page-checksum validation, backup-completeness semantics that WAIT for
  the WAL segments that make a backup consistent, async WAL push/get,
  encrypted repositories on S3-compatible stores (B2 exposes exactly
  that), and ransomware recovery via versioned object storage. WAL-G
  (Go, multi-DB incl. MariaDB/Redis) is the alternative and wins only
  if a MariaDB tenant buys the tier first. Design constraints recorded
  now: PITR artifacts live in PER-TENANT repository prefixes (the
  iter-14 side-channel rule), `archive_timeout=300` sets the RPO
  ceiling (~5 min), the PITR tier's monthly restore drill replays to a
  POINT IN TIME, and - unlike the snapshot tier - PITR does not remove
  the nightly file-consistency stop for non-DB paths. Trigger: a signed
  contract with RPO < 24h; priced as an add-on like the isolation/WAF
  tiers.
- **Second offsite (loop iter 38):** against the 3-2-1-1-0 rule the
  platform currently holds TWO copies (local restic on the tank mirror;
  B2 offsite) - the missing third copy is also a SINGLE-VENDOR risk
  (B2 credentials could delete the only offsite). The mechanism is
  restic's own `copy` command: a second repository at a DIFFERENT
  provider's S3-compatible endpoint, initialized with `--copy-chunker-
  params` for cross-repo dedup, its OWN repo password (separate
  compromise blast radius), fed weekly by `restic copy --from-repo`
  (idempotent - already-copied snapshots skip). The copy destination
  is NEVER auto-pruned: forget runs on it only at the annual rehearsal,
  making it effectively append-only against credential-driven deletion.
  Object Lock on the B2 bucket was considered and REJECTED: it fights
  the automated prune (locked objects block retention deletion ->
  unbounded cost) and does nothing about single-vendor risk, which is
  the actual threat. Trigger: the first paying customer (same gate as
  the DR rehearsal). The "0 errors" leg is already shipped - the weekly
  `restic check` and the monthly restore drill (iters 4/26).
- **Disk hygiene (loop iter 43):** renovate's tag bumps leave every old
  image on disk, and `/var/lib/docker` lives on the SYSTEM disk - not
  the quota'd data disk (iter 9's per-tenant quota does not see it).
  Monthly, inside the yielding sweep window: unused images older than
  14 days (the rollback window) and dead containers older than 7 days
  are pruned; volumes are NEVER pruned (customer data). The other half
  is loudness: the tenant watchdog pages at 85% on both the system and
  data disks, so growth is seen whether or not the prune ran.
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
Argo) are K8s reconcilers; rejected: our convergence target is compose +
ansible on one host, not a cluster API. Kamal-class tools ship APP
artifacts over SSH; rejected for infra convergence, noted for future
tenant-app deploys. The cutting edge that fits is the **Standard
Webhooks** spec (v1.0: `webhook-id`/`webhook-timestamp`/`webhook-signature`
headers, `v1` HMAC-SHA256 + `v1a` ed25519, space-delimited multi-signature
for zero-downtime key rotation, idempotency via `webhook-id`, 2xx =
success / 410 disables endpoint, exponential-backoff retry schedules
spanning days with jitter, 15-30s consumer timeouts, SSRF proxy
guidance). Policy: inbound GitHub deploy events keep `X-Hub-Signature-256`
(interop constraint; Standard Webhooks explicitly supports side-by-side
legacy schemes); OUTBOUND estate webhooks (webhookkit senders, eventbusd
consumers) adopt Standard Webhooks v1 signatures + idempotency keys -
recorded as the webhookkit crate enhancement. Internal deploy webhooks
keep fast-fail retries (4x/30s) because eventbusd holds durability; the
days-long backoff schedules apply to customer-facing senders when the
estate grows them.

### Config drift

**Drift research (loop iter 22):** the OpenGitOps principles v1.0
(declarative, versioned+immutable, pulled, CONTINUOUSLY RECONCILED)
name the property the legacy deploy path lacked: reconciliation. Our
deploy is a force-sync (`git reset --hard` + compose/ansible), which
makes drift SILENT by construction; the Oct-11 incident was exactly
this class (live hotfixes in the checkout that the next deploy would
wipe; a hand-edited appdata dynamic.yml diverging from the tracked
copy). K8s reconcilers solve this with agents diffing desired vs
actual; the lean equivalent is two checks at the force-sync boundary:
the meta-watchdog now reports uncommitted/ahead state on the TrueNAS
checkout (any drift pages, because a force-sync WILL destroy it), and
the deploy pipeline syncs `stacks/proxy/config/dynamic.yml` into
appdata (traefik's watched file provider picks it up live); the repo
copy is canonical, hand-edits to the live file get overwritten with a
diff on next deploy instead of silently diverging.

---

## Bare-metal runbook (order matters)

### 0. Before the server arrives

- [ ] Business broadband installed, **static IP or DHCP reservation**
      confirmed NOT CGNAT (test: router WAN IP == what `curl ifconfig.me`
      returns from inside the LAN)
- [ ] ISP **IPv6 prefix delegation** confirmed or explicitly unavailable
      (iter 37: AAAA readiness; Caddy/fence/input-chain are already
      dual-stack; only DNS and the ISP are missing pieces)
- [ ] Ports 80/443 reachable from outside (test with a laptop hotspot)
- [ ] Companies House, ICO registration, insurance done (see service catalogue)
- [ ] `secrets/hosting.env.encrypted` created and its `RESTIC_PASSWORD`
      recorded in the password manager **and** on paper in the safe
- [ ] CAA record on the registered domain: `0 issue "letsencrypt.org"`
      (iter 25; add `;accounturi=<ACME account URL>` once the account
      exists; pin issuance to our account so a domain hijack alone
      cannot mint certificates). Every customer domain gets the same at
      onboarding.
- [ ] Processor DPA template drafted (iter 33; UK GDPR Art 28); signed
      with each customer before the first tenant data lands.
- [ ] **UPS fitted** (iter 34: on-prem means power cuts are the most
      likely physical threat): double-conversion unit sized for the
      full build, runtime >= 2x the measured graceful-shutdown path
      (tenants stop -> VMs down -> host off, ~5 min) so a cut during
      the nightly backup window degrades to a delayed backup, not a
      dead ZFS pool; USB (or SNMP) cable to the PVE host; Network UPS
      Tools (NUT 2.8.x) as the shutdown machinery below.

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

- **NUT master** (iter 34); the PVE host owns the UPS cable and serves
  power state to its guests (NUT 2.8.x, apt `nut`):

  ```bash
  # /etc/nut/ups.conf:  [ups] driver = usbhid-ups port = auto
  # /etc/nut/upsd.conf: LISTEN 0.0.0.0 3493   (mgmt LAN only)
  # /etc/nut/upsd.users: [upsmon] password = <sops secret>  upsmon master
  # /etc/nut/upsmon.conf:
  #   MONITOR ups@localhost 1 upsmon <pass> master
  #   SHUTDOWNCMD "/sbin/shutdown -h now"   # PVE stops its VMs first
  #   MINSUPPLIES 1
  systemctl enable --now nut-driver nut-server nut-monitor
  upsc ups@localhost ups.status   # expect: OL (online)
  ```

- **Authenticated time (NTS)** (iter 45); everything downstream trusts
  the clock: JWT exp/nbf validation, GCRA rate limiting, TLS/ACME
  windows, log correlation. Unauthenticated NTP (or timesyncd, which
  cannot detect falsetickers at all) lets a MITM steer the clock. PVE
  ships chrony; replace its sources with NTS-authenticated ones
  (chrony >= 4.0, RFC 8915):

  ```bash
  # /etc/chrony/sources.d/nts.sources on the PVE host AND docker01:
  #   server time.cloudflare.com iburst nts
  #   server gbg1.ntp.netnod.se iburst nts
  #   server mm1.ntp.netnod.se iburst nts
  #   minsources 2
  #   maxchange 100 0 0      # panic on absurd offsets; do NOT auto-restart
  #   makestep 1 3
  #   rtcsync
  systemctl restart chrony
  chronyc -N authdata   # expect non-zero KeyID/Type/KLen per server
  ```

  Guests inherit a correct host clock via kvm-clock, but run chrony
  with NTS anyway to bound guest-local skew. NTS chicken-and-egg is
  covered: VMs have no battery-backed RTC, so `rtcsync`+`makestep`
  keep boot time close enough for the NTS-KE certificate check.

  Guest VMs (docker01) run `nut-client` as upsmon SLAVEs pointing at
  the PVE mgmt IP: when the battery hits the low-battery threshold,
  upsmon raises FSD everywhere and the ordering falls out of the
  dependency - guests shut down (systemd stops docker cleanly), THEN
  the host. Runtime sizing above covers the whole path; test it with
  `upsmon -c fsd` during the DR rehearsal.

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
- [ ] `upsmon` on docker01 reports the shared UPS as OL and slave-connected
      (iter 34): `upsc ups@<pve-mgmt-ip> ups.status`
- [ ] `curl -sI https://<first-tenant-domain>` shows the iter-48 header
      set (Strict-Transport-Security, X-Content-Type-Options,
      Referrer-Policy) and no `Server` header
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

1. `terraform destroy` is **not** part of the drill; do not nuke production.
   Instead: restore drill per tenant (`tenant-backup.sh --restore`) on a
   scratch VM.
2. Annually (or before a node migration): full rebuild in a maintenance
   window; new VM from Terraform, bootstrap, restore all tenants from B2,
   compare against the live host, then cut over.
3. Keep the drill notes in `.docs/`; an unrehearsed runbook is a wish,
   not a plan.
