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

**Edge research (loop iter 2):** Pingora (Cloudflare's Rust proxy
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

### Backups and recovery

- Per tenant: `ops/tenant-backup.sh` — restic snapshot tagged
  `tenant:<slug>` into `/srv/backups/restic`, copied offsite to B2.
- **Backup research (loop iter 4):** restic's Rabin chunking (512 KiB
  avg) vs kopia's FastCDC-class chunking was evaluated — FastCDC wins on
  chunking throughput but switching tools buys nothing here: measured
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
- **Node loss** = reinstall Proxmox per this runbook, `terraform apply`,
  `ansible-playbook hosting_bootstrap.yml`, `restic restore` per tenant.
  Rehearse this before the first paying customer (see checklist).

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
