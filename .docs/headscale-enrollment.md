# Headscale VPN Enrollment Guide

## VPN Network Status

| Node | IP | Status |
|------|-----|--------|
| msi-ge66 (laptop) | 100.64.0.1 | Online |
| cachyos-x8664 (headless server, .191) | 100.64.0.2 | Online |
| wyattdeskacercachy (Acer desktop) | 100.64.0.3 | Online |
| truenas (exit node) | 100.64.0.8 | Online |

**Server**: `https://headscale.wyattau.com` — **direct A record (DNS only), never proxy
this hostname through Cloudflare**: the TS2021 noise handshake is a POST-based upgrade
that CF's edge strips (500) — and do NOT add websocket-header-rewriting middlewares in
Traefik (a `headscale-ws` middleware caused 405s; removed 2026-09-01).

**Pre-auth key**: do not store keys in this doc (they expire silently — caused the
2026-09-01 outage). Mint one on demand:

```bash
ssh truenas 'sudo docker exec headscale-server headscale preauthkeys create --user 1 --reusable --expiration 90d'
```

CachyOS laptops self-enroll: write the key to `/etc/tailscale/headscale-authkey`
(root, 0600) and `sudo systemctl start tailscale-enroll.service` — the systemd timer
retries hourly until a valid key appears (Ansible `local.yml` section 10g).

---

## Arch Linux / CachyOS

```bash
# Install
sudo pacman -S tailscale

# Enable daemon
sudo systemctl enable --now tailscaled

# Connect to Headscale
sudo tailscale up \
  --login-server https://headscale.wyattau.com \
  --authkey YOUR_PREAUTH_KEY_HERE \
  --hostname <your-hostname> \
  --accept-routes

# Verify
tailscale status
ping 100.64.0.8  # TrueNAS exit node
```

---

## Windows

1. Download Tailscale from https://tailscale.com/download/windows
2. Install and run
3. Open PowerShell **as Administrator**:
```powershell
tailscale up `
  --login-server https://headscale.wyattau.com `
<<<<<<< HEAD
  --authkey YOUR_PREAUTH_KEY_HERE `
=======
  --authkey hskey-auth-y0whvJtmNahI-Uj-HSwUcCn6v09UBFHt_P48ykjETR_D1MPh14QxvNslB0NwTkhiLYmdA5cN3kTQi `
>>>>>>> 54a2c80 (docs: fix headscale enrollment — real node names, direct DNS requirement, no keys in doc)
  --hostname windows-pc `
  --accept-routes
```
4. Verify: `tailscale status`

---

## Android

1. Install **Tailscale** from Play Store / F-Droid
2. Open app
3. Tap the three dots (⋮) → **Use custom coordination server**
4. Enter: `https://headscale.wyattau.com`
5. Tap **Sign in with auth key**
6. Paste the pre-auth key
7. Connect

---

## iOS

1. Install **Tailscale** from App Store
2. Open app → Settings (gear icon)
3. **Use custom server** → Enter: `https://headscale.wyattau.com`
4. Sign in with the pre-auth key

---

## After Enrollment

Once connected, you can:
- **Access TrueNAS**: `ssh truenas_admin@100.64.0.8` or via Tailscale hostname
- **Access CachyOS**: `ssh wyatt@100.64.0.3`
- **Use exit node**: Route all traffic through TrueNAS
  ```bash
  sudo tailscale up --exit-node=100.64.0.8
  ```

## Verify on Server

```bash
# List all nodes (run on TrueNAS)
sudo docker exec headscale-server headscale nodes list
```
