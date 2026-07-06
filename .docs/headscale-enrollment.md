# Headscale VPN Enrollment Guide

## VPN Network Status

| Node | IP | Status |
|------|-----|--------|
| truenas-1 (exit node) | 100.64.0.2 | Online |
| cachyos-runner | 100.64.0.3 | Online |

**Server**: `https://headscale.wyattau.com`
**Pre-auth key** (reusable, expires 2026-10-02):
```
hskey-auth-6A1bCBRxMCsR-kGSg0zQiNHQMjc6N3B8A3Lf0RL-KfL5wDJCBQylDmAaWsvIBRwJTwmLlW-WC3jHV
```

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
  --authkey hskey-auth-6A1bCBRxMCsR-kGSg0zQiNHQMjc6N3B8A3Lf0RL-KfL5wDJCBQylDmAaWsvIBRwJTwmLlW-WC3jHV \
  --hostname <your-hostname> \
  --accept-routes

# Verify
tailscale status
ping 100.64.0.2  # TrueNAS exit node
```

---

## Windows

1. Download Tailscale from https://tailscale.com/download/windows
2. Install and run
3. Open PowerShell **as Administrator**:
```powershell
tailscale up `
  --login-server https://headscale.wyattau.com `
  --authkey hskey-auth-6A1bCBRxMCsR-kGSg0zQiNHQMjc6N3B8A3Lf0RL-KfL5wDJCBQylDmAaWsvIBRwJTwmLlW-WC3jHV `
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
- **Access TrueNAS**: `ssh truenas_admin@100.64.0.2` or via Tailscale hostname
- **Access CachyOS**: `ssh wyatt@100.64.0.3`
- **Use exit node**: Route all traffic through TrueNAS
  ```bash
  sudo tailscale up --exit-node=100.64.0.2
  ```

## Verify on Server

```bash
# List all nodes (run on TrueNAS)
sudo docker exec headscale-server headscale nodes list
```
