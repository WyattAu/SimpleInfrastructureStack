# Tailscale Enrollment

**Status: CURRENT (2026-11-14).** Supersedes the retired Headscale setup
(`headscale.wyattau.com`, pre-auth key expired 2026-10-02). The fleet runs on
real Tailscale.

## Tailnet

| Property | Value |
| --- | --- |
| Control plane | `https://controlplane.tailscale.com` |
| MagicDNS suffix | `tail2d2a7d.ts.net` |

| Node | Tailnet IP | Role | State |
| --- | --- | --- | --- |
| `wyattdeskacercachy` | 100.93.183.32 | workstation, LAN gateway | active |
| `truenas-1` | 100.124.36.11 | NAS: Forgejo, PG, SIS stacks | active |
| `josh-laptop` | 100.101.206.65 | | offline |
| `msi-ge66` | 100.70.111.14 | | offline |
| `wyatts-a53` | 100.74.27.26 | Android | offline |

Stale record to delete in the admin console: node `truenas` at
100.108.170.51 (the pre-2026-11-14 registration, offline). Once deleted,
`truenas-1` can be renamed to `truenas` with
`tailscale set --hostname=truenas`.

## NAS (TrueNAS SCALE 25.04.2.4)

The NAS runs Tailscale as a **standalone Docker container**, not a TrueNAS
service or app:

| Setting | Value |
| --- | --- |
| Image | `ghcr.io/tailscale/tailscale:latest` |
| Network | `host` |
| Capabilities | `NET_ADMIN` + `/dev/net/tun` |
| Restart policy | `unless-stopped` |
| State volume | `/mnt/pool_HDD_x2/tank/datasources/sis/appdata/tailscale` → `/var/lib/tailscale` |
| Env | `TS_HOSTNAME=truenas`, `TS_USERSPACE=false`, `TS_STATE_DIR=/var/lib/tailscale`, `TS_EXTRA_ARGS=--accept-routes`, `TS_AUTHKEY=<reusable key>` |

### Why `TS_STATE_DIR` is mandatory

`containerboot` defaults to `--state=mem: --statedir=/tmp` when an auth key is
set. With in-memory state, **every container restart re-authenticates with the
auth key and registers a new node**  -  that is how the stale `truenas` record
was created. `TS_STATE_DIR=/var/lib/tailscale` puts `tailscaled.state` on the
mounted volume; restarts then reuse the same node and IP.

Verified 2026-11-14: `docker restart tailscale` → same node (`truenas-1`) and
same IP (100.124.36.11).

### Re-authenticate / rebuild the container

```sh
KEY=$(sudo docker inspect tailscale --format '{{range .Config.Env}}{{println .}}{{end}}' \
      | sed -n 's/^TS_AUTHKEY=//p')
sudo docker rm -f tailscale
sudo docker run -d --name tailscale --restart unless-stopped --network host \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -v /mnt/pool_HDD_x2/tank/datasources/sis/appdata/tailscale:/var/lib/tailscale \
  -e TS_AUTHKEY="$KEY" -e TS_HOSTNAME=truenas -e TS_USERSPACE=false \
  -e TS_STATE_DIR=/var/lib/tailscale -e TS_EXTRA_ARGS="--accept-routes" \
  ghcr.io/tailscale/tailscale:latest
```

If the stored key has expired, generate a new auth key in the admin console
(Settings → Keys) and use it in place of `$KEY`.

## Access

```sh
ssh -i ~/.ssh/id_ed25519 truenas_admin@100.124.36.11     # tailnet
ssh -i ~/.ssh/id_ed25519 truenas_admin@192.168.1.3       # LAN (unchanged)
```

MagicDNS: `truenas-1.tail2d2a7d.ts.net`.

## Gotchas

- **The TrueNAS UI is on `:8080`.** Ports 80/443 belong to Traefik (k3s);
  `https://192.168.1.3/` returns 404.
- **SSH keys live in the TrueNAS user record.** Credentials → Users →
  `truenas_admin` → SSH Public Key holds *all* keys; TrueNAS rewrites
  `~/.ssh/authorized_keys` from it. Edit the record, not the file. A key
  pasted without its `ssh-ed25519 ` prefix is stored verbatim and silently
  never matches.
- **`/etc/ssh/sshd_config` has `Match User "truenas_admin"`** enabling password
  auth for that account only; pubkey auth is global.
- The workstation reports a Tailscale health warning about systemd-resolved /
  NetworkManager wiring. MagicDNS resolution still works
  (`getent hosts truenas-1.tail2d2a7d.ts.net`), but the warning is unresolved.
- Enrolling the NAS removes the dependency on the workstation being up as the
  only route to the NAS.
