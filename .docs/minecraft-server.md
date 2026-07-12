# Minecraft Server (mc-purpur)

## Status: RUNNING

| Setting | Value |
|---------|-------|
| Container | Incus `mc-purpur` on CachyOS (192.168.1.191) |
| Software | Purpur (MC 1.21) + GeyserMC + Floodgate |
| Java | Eclipse Temurin 21.0.11 |
| JVM Heap | 3GB (Aikar's GC flags) |
| CPU | 2 cores |
| Memory Limit | 4GiB |
| Java Port | TCP 25565 |
| Bedrock Port | UDP 19132 |
| DNS | mc.wyattau.com → 62.49.88.159 (grey-cloud/DNS-only) |

## Connect

**Java Edition:** `mc.wyattau.com:25565` (or `192.168.1.191` on LAN)
**Bedrock Edition:** `mc.wyattau.com:19132` (or `192.168.1.191` on LAN)

## Management Commands

All commands run from CachyOS host (192.168.1.191):

```bash
# Start/stop/restart server
incus exec mc-purpur -- systemctl start minecraft
incus exec mc-purpur -- systemctl stop minecraft
incus exec mc-purpur -- systemctl restart minecraft

# View server console (Ctrl+B then D to detach)
incus exec mc-purpur -- su - minecraft -c "tmux attach -t mc-server"

# Send command to console
incus exec mc-purpur -- tmux send-keys -t mc-server "say Hello!" Enter

# Check status
incus exec mc-purpur -- systemctl status minecraft

# View container resources
incus info mc-purpur
```

## Manual Setup Required

### Router Port Forwarding (CRITICAL)
Your Vodafone router needs two port forwarding rules:

1. **TCP 25565** → `192.168.1.191` (CachyOS LAN IP)
2. **UDP 19132** → `192.168.1.191` (CachyOS LAN IP)

Without this, external players cannot connect. LAN players can connect immediately.

### Optional: ViaVersion Plugin
Geyser recommends ViaVersion for cross-version Java compatibility:
```bash
incus exec mc-purpur -- su - minecraft -c \
  "curl -o /opt/minecraft/plugins/ViaVersion.jar \
  https://ci.viaversion.com/job/ViaVersion/lastStableBuild/artifact/build/libs/ViaVersion.jar"
incus exec mc-purpur -- systemctl restart minecraft
```

## File Locations (inside container)

| Path | Description |
|------|-------------|
| `/opt/minecraft/purpur.jar` | Server binary |
| `/opt/minecraft/plugins/` | Geyser, Floodgate, ViaVersion |
| `/opt/minecraft/world/` | Overworld |
| `/opt/minecraft/world_nether/` | Nether |
| `/opt/minecraft/world_the_end/` | The End |
| `/opt/minecraft/start.sh` | Startup script (Aikar's GC) |
| `/opt/minecraft/eula.txt` | EULA acceptance |
| `/etc/systemd/system/minecraft.service` | systemd service |

## Backup

To snapshot the container:
```bash
incus snapshot mc-purpur pre-update
```

To restore:
```bash
incus restore mc-purpur pre-update
```

World data is on btrfs with CoW disabled for performance.
