# SIS review guide — hosting platform bring-up (iteration 29 + 30)

> **READ FIRST — SECURITY FINDING (2026-11-24):** this repo is **PUBLIC**
> on GitHub and its committed history contains: the eventbusd bearer
> token (`ansible/group_vars/hosting.yml`), the ntfy alert topic
> (README + architecture docs), a literal headscale postgres password
> (`stacks/headscale/docker-compose.yml`), and deleted realm secrets
> recoverable from history (`iam/config/keycloak/ocis-realm.dist.json`).
> Rotation status: **ntfy topic ✓ rotated** (new topic
> `wyattau-infra-105ce3fa…` — SUBSCRIBE on your phone, the old topic is
> dead), **eventbusd token ✓ rotated** (server-side verified: old 401,
> new 200; guests ship it via bootstrap), **headscale pg password ✗
> pending a maintenance window** (runbook below — it is the tailnet
> control plane). The batch adds `gitleaks-baseline.json` (all 22
> findings, redacted) + a baseline-gated gitleaks job in
> `auto-deploy.yml` so no NEW secret can deploy. As rotations land,
> shrink the baseline.
> Also decide the doctrine question: public repo (open-source stack,
> sanitized secrets) vs private repo. That decides how much operational
> detail (iteration 29/30 in the loop doc contains tonight's full
> infra story) belongs in the push.

The uncommitted tree is the hosting01 platform: two PVE VMs (production
docker01 + staging docker02), a one-command deploy wrapper, the tenant
pipeline, monitoring, backups, snapshots, and the watchdog. The full
narrative — 19+ defects with root causes — is in
`.docs/engineering-loop.md`, iteration 29 and the overnight audit that
follows it.

## Suggested review order (riskiest first)

1. **`secrets/hosting.env.encrypted`** — generated secrets: restic
   password + hosting-api token (B2 intentionally empty). `sops -d` to
   inspect. **The restic password must be copied to your password
   manager — losing it loses every tenant backup.**
2. **`ops/hosting/deploy.sh`** — the one-command deploy path. Note the
   `--replace docker0X` flag destroys a VM and rebuilds through the
   wrapper only (proven on staging).
3. **`terraform/hosting/docker02.tf`** — new staging VM (120).
4. **`ansible/roles/hosting_docker_host/`** — 9 fixes: cloud-init
   snippet out-of-terraform-state, dockremap ordering + controller-side
   lookup bug, quota-feature strip (mount-breaking kernel bug), daemon
   JSON string fix, userns exporter conversions, dashboard rsync+deps,
   nftables per-table flush (Docker NAT survival), cAdvisor flags.
5. **`ansible/roles/hosting_edge/tasks/main.yml`** — Caddy repo URL fix
   + log-dir ownership race.
6. **`ansible/inventory/`** — group_vars/host_vars relocated under
   `inventory/` (cwd-based resolution is invisible to plays);
   ansible_host now resolved per-deploy into host_vars.
7. **`scripts/hosting-ci.sh` + `check-image-pins.py`** — static gates
   for every defect class. Currently the pins gate is
   environment-limited (ghcr 403/404 flakiness tonight); do not weaken
   it — re-run when ghcr cooperates.
8. **`stacks/monitoring/victoriametrics/scrape.yml`** — adds docker01/02
   scrape targets (deploys with this push).
9. **`ops/tenant-provision.sh` / `ops/tenant-backup.sh`** — template
   resolution, restic init-on-first-use, stack-restart guarantee,
   data-uid chown under userns, registry-truth pins.
10. **Docs**: `.docs/hosting-architecture.md` corrected to the real
    node (rpool RAID10, no `tank`), iteration 29/30 in the loop doc.

## Runtime state (verified live, 2026-11-24)

| | docker01 (prod) | docker02 (staging) |
|---|---|---|
| mgmt IP | 192.168.0.127 (DHCP) | 192.168.0.129 (DHCP) |
| tenant IP | 10.10.10.10 | 10.10.10.20 |
| services | api/dash/caddy/docker active | same + canary |
| endpoints | api 200, dash 200 | api 200, dash 200, canary healthz 200 via edge |

Timers on both: watchdog 15 min (alert-dedup 60 min),
`zfs-snap.timer` hourly on hosting01 (48 hourly / 14 daily).
hosting-api nightly sweep 03:30 UTC. Backups currently LOCAL ONLY —
the watchdog pages `OFFSITE BACKUP STALE` hourly (dedup) until B2 is
provisioned; that page is the signal, not noise.

## Also in the batch (newer pieces)

- `ops/hosting/zfs-snap.sh` — installed on hosting01 (hourly timer, 48
  hourly/14 daily snapshots of the VM disks). Node-side state, not
  Ansible-managed: re-install after node rebuilds.
- `ops/hosting/deploy.sh` — ends with a per-host verify phase
  (services active + api/dash endpoints 200); deploy exits 1 on verify
  failure. Treat that exit as blocking for tenant onboarding.
- `.github/workflows/hosting.yml` — the static gates run on GitHub CI
  for stack-affecting paths (`--offline` pins check on runners; run the
  registry-truth check locally, ghcr throttles runner IPs).
- Watchdog alert dedup — unchanged failure sets re-page at most hourly
  (60 min window, change-sets page immediately); systemd keeps the
  failed-unit marker between pages. Tunable via
  `hosting_watchdog_repeat_min`.
- Edge liveness probe now uses Caddy's admin API (the old :80/SNI probe
  false-alarmed on internal-cert-only sites).

## Identity chain (tenant logins) — blocked, one sudo command away

hosting-api's OIDC issuer (authbox, NAS:9005) is unreachable from the
guests: the only inter-segment router is the workstation and its
FORWARD rules predate the hosting platform. Unblock (operator sudo):

    iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -I FORWARD 2 -i wlan0 -o enp3s0 -s 192.168.0.0/24 -d 192.168.1.0/24 -j ACCEPT

then test from docker01: `curl -m8 http://192.168.1.3:9005/.well-known/openid-configuration`.
Until then: legacy break-glass token auth works; authbox login flows fail.
Durable fix = hosting01 gateway VM (same SPOF as the LAN cable).

## Pending: headscale postgres password rotation (maintenance window)

The old password is public (tracked config.yaml + compose). Rotation
needs a brief tailnet-control outage — do it in a window:

    # 1. SIS: update stacks/headscale/docker-compose.yml POSTGRES_PASSWORD
    #    and stacks/headscale/config/config.yaml `pass:` — BUT move both
    #    files out of git first (the tracked copies re-leak any new
    #    value): git rm --cached + real files in the NAS appdata dir.
    # 2. Push; auto-deploy pulls the new compose.
    # 3. On the NAS (headscale-postgres runs with the OLD password until
    #    the volume is recreated — use docker exec for the live change):
    sudo docker exec headscale-postgres psql -U headscale -d headscale \
      -c "ALTER USER headscale WITH PASSWORD '<NEW>';"
    sudo docker restart headscale-server
    # 4. Verify: tailscale nodes still report; headscale health 200.
    # NOTE: POSTGRES_PASSWORD env only seeds NEW volumes — the ALTER USER
    # is the real rotation for the existing database.

## Watch out

- The watchdog's exit-1 marks the unit failed in systemd while any
  check is red — `systemctl --failed` is the triage entry point.
- ProxyJump to 10.10.10.x is broken (OpenSSH hostbound + auth mystery);
  Ansible uses mgmt IPs. Revisit with a dedicated deploy key if you
  want the tenant-bridge path.
- The pins gate stays red until ghcr stops 404ing EIR manifests
  (registry-side flakiness, not missing pins — verified ferro + postgres
  interactively).
