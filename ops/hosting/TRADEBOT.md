# Tradebot VM (130) — operator setup guide

Provisioned 2026-11-26 (iteration 30). Everything here is what you need to
land the bot. No secrets in this file — ever (SIS is public).

## The host: hosting01 (R730)

| Fact | Value |
|---|---|
| Chassis | Dell PowerEdge R730 |
| CPU | 2× Intel Xeon E5-2620 v4 @ 2.10GHz (16c/32t total) |
| RAM | 39 GiB usable |
| Hypervisor | Proxmox VE, node name `hosting01` |
| VM datastore | `local-zfs` — 3.2 TB ZFS pool, ~96% free |
| Mgmt IP | `192.168.0.120` (reverted from the `192.168.1.50` re-address — the Cloudflare record for hosting01.wyattau.com is stale) |
| Access | `ssh -i ~/.config/opencode/keys/hosting01-deploy-ed25519 root@192.168.0.120` |
| Tenants | ZFS snapshots nightly (`zfs-snap.sh`), backup sweep 04:00 UTC |

### Guest map

| VMID | Name | Role | RAM | Disk |
|---|---|---|---|---|
| 110 | docker01 | **paying tenant production** | 20 GiB | 100 GiB |
| 120 | docker02 | staging | 6 GiB | 60 GiB |
| 130 | tradebot | **your bot — isolated** | 4 GiB | 32 GiB |
| 9000 | template | Ubuntu 24.04 cloud-image | — | — |

Rules of the road: docker01 is the customer's production. Nothing new goes on
it without a review. The tradebot never shares a guest, a compose stack, or a
bridge with tenant workloads.

## The VM: tradebot (130)

| Fact | Value |
|---|---|
| VMID | 130 |
| Resources | 2 vCPU (host passthrough), 4 GiB RAM, 32 GiB SSD (discard+iothread) |
| IP | `192.168.0.113` (DHCP on the `.0.x` router segment) — pin it with a DHCP reservation on the router when convenient |
| NIC | vmbr0 **only** — no tenant bridge, no route to `10.10.10.0/24`, NAT egress |
| Access | `ssh -i ~/.config/opencode/keys/hosting01-deploy-ed25519 wyatt@192.168.0.113` |
| Installed | Docker + Compose v2 (see versions below), qemu-guest-agent, ufw |
| Firewall | ufw: deny all inbound, allow SSH from `192.168.0.0/24` only, outbound unrestricted |
| Key slot | `/home/wyatt/keys/` — mode `0700`, owner `wyatt` |
| Terraform | `terraform/hosting/tradebot.tf` in SIS (state: `terraform/hosting/terraform.tfstate`) |
| Cloud-init | `ops/hosting/tradebot-user-data.yaml` → `/var/lib/vz/snippets/` on hosting01 |
| Log rotation | Docker daemon capped at 3 × 10 MB per container (daemon.json) |

Check versions live: `ssh wyatt@192.168.0.113 "docker --version; docker compose version"`.

## Setup checklist (in order)

1. **Keys** — create one API key per venue on the guest, in the key slot:
   ```
   ssh wyatt@192.168.0.113
   nano ~/keys/<venue>.env      # mode 0600; COMPOSE can env_file: it
   ```
   Key hygiene (non-negotiable):
   - **Trade-only scopes.** Withdrawals disabled at the venue.
   - **IP-lock** the key to your egress IP if the venue supports it.
   - One key per venue, one per purpose — no shared god-keys.
   - Nothing key-shaped goes into SIS, compose files, logs, or chat.

2. **Dry-run first** — run the bot in paper mode for at least a few days.
   Verify entries/exits/sizing against what you expect before real orders.

3. **Limits before live** — hard spend cap per order, max daily loss (kill
   switch), and a way to flatten positions manually without the bot.

4. **Stack layout** — keep the bot self-contained on the guest:
   ```
   ~/bot/
   ├── docker-compose.yml     # image, restart: unless-stopped
   ├── .env                   # non-secret config
   └── (volumes under ~/bot/data/)
   ```
   Do **not** commit this stack to SIS (public). Private repo or
   guest-local only.

5. **Watch it** — `docker compose logs -f` on the guest; optionally expose
   metrics later (a read-only metrics port bound to the LAN).

## What's deliberately NOT done (your calls)

- **DHCP reservation** for `192.168.0.113` — router-side, when convenient.
- **Venue + strategy** — bring your own; provision stopped at a clean,
  docker-ready, firewalled guest.
- **Live execution** — the risk review requires dry-run + human review of
  the first cycle before real orders. That's the sequence this doc assumes.
- **Backups** — the tenant backup sweep does NOT cover this VM. If you want
  the bot's state snapshotted, say so and it gets added deliberately.

## Provisioning reference (how this VM was built)

```bash
# snippets (lint + upload to hosting01)
bash ops/hosting/deploy-cloudinit.sh 192.168.0.120

# terraform (from SIS root)
cd terraform/hosting
export TF_VAR_pve_endpoint="https://192.168.0.120:8006/"
export TF_VAR_pve_api_token="$(cat ~/.config/opencode/keys/pve-hosting01-terraform)"
export TF_VAR_datastore_id="local-zfs"
terraform apply -input=false -auto-approve   # plan showed 1 to add, 0 touched
```

Rebuild from scratch: `terraform apply -replace=proxmox_virtual_environment_vm.tradebot`.
The guest is stateless by design — keys live on the venue side and in
`~/keys/`, so a rebuild costs you the compose stack only.
