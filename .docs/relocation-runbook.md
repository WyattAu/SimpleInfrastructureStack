# Server Relocation Runbook

## Architecture (interim: workstation NAT gateway)
```
Internet ← Hyperoptic CGNAT ← TP-Link BE7200 (192.168.0.1)
    ↓
Workstation (192.168.0.105, wlan0) ← sis-gateway.service
    ↓ enp3s0 (192.168.1.1/24)
    ↓
Switch ← TrueNAS (192.168.1.3) + CachyOS (192.168.1.191)
```

## Pre-shutdown checklist
1. `sudo /mnt/pool_HDD_x2/infra/stacks/stacks/backup/scripts/backup.sh`
   - Verify "Offsite sync completed successfully"
2. Verify B2: `sudo docker exec backup-restic restic --password-file /tmp/restic-pass -r "s3:https://s3.eu-central-003.backblazeb2.com/SisInfraBackup/repo" snapshots --latest 1`
3. Git: all repos pushed (SIS, EIR, EvergreenShims, ferro, QuestHive)
4. CachyOS: `sudo /opt/sis-backup/cachyos-backup.sh`
5. CachyOS: `sudo docker stop $(sudo docker ps -q)` (graceful)
6. TrueNAS: `sudo docker stop $(sudo docker ps -q)` (graceful)
7. TrueNAS: `sudo zpool export pool_HDD_x2`
8. Power off

## New site bring-up
1. Cable: switch → workstation enp3s0, TrueNAS + CachyOS on same switch
2. Router: DHCP reserve .3 (TrueNAS), .191 (CachyOS), .105 (workstation)
3. Router: forward TCP 443 → 192.168.0.105 (for josh via workstation DNAT)
4. Router: forward TCP 2222 → 192.168.0.105 (git SSH)
5. Power: TrueNAS → CachyOS → workstation
6. TrueNAS: pools import → docker starts (boot-race drop-in prevents empty state)
7. Wait 5 min for ddns → headscale.wyattau.com → new public IP
8. Verify: `curl http://192.168.1.3:8080/health` (LAN control)
9. Verify: `curl https://headscale.wyattau.com/health` (public, tests forward)
10. josh-laptop auto-reconnects

## Recovery procedures
See .docs/incident-2026-09-relocation.md for detailed procedures.

## Known limitations (interim architecture)
- Workstation = single point of failure (all internet flows through it)
- Hyperoptic CGNAT = no inbound from internet (josh cut off without VPS)
- Wifi = backup bandwidth bottleneck
