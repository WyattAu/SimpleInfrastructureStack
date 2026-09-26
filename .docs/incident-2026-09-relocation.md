# Incident 2026-09: Relocation Network Transition

## What happened
Servers moved onto an intermediate gateway (workstation NAT over wifi).
Within 48h: offsite backups silently failing (12 days), monitoring
blind (6 days), Forgejo flooded by 5,992 spam accounts, 4 monitoring
healthchecks revealed as never-have-worked.

## Root causes & fixes (all permanent)
| Failure | Root cause | Permanent fix |
|---|---|---|
| Offsite backup silent failure | B2 endpoint DNS returned AAAA-first; docker ULA v6 can't route to internet | extra_hosts v4 pin in backup compose |
| Offsite failure unnoticed 12d | No independent meta-monitoring | CachyOS watchdog (ops/sis-watchdog.sh, 15min timer) |
| Monitoring blind 6d | VM lost backend_net attach after IP conflict; boot-race left orphaned bridges | VM compose now declares backend_net; orphaned bridges deleted |
| Docker "lost" 40 containers | Boot-race: docker started before ix-apps dataset mounted | docker.service drop-ins (wait for dataset, After=zfs-mount) |
| Crowdsec crash-loop | Console enrollment expired; watcher machine deregistered from DB | machines re-registered from local_api_credentials.yaml |
| Paperless crash-loop 15k restarts | EIR redis protected-mode rejects passwordless clients | requirepass + authenticated URL |
| 4 monitoring healthchecks broken forever | String-form YAML tests (never valid) | shim TCP probes |
| CachyOS offline after reboot | Static IP applied live, never persisted | nmcli profile "lan" (persistent) |
| Forgejo spam flood | Open registration on internet-exposed instance | DISABLE_REGISTRATION=true; 5,992 spam users purged |

## Recovery procedures that worked (for future reference)

### Docker empty-state recovery (boot-race)
1. `sudo systemctl restart docker` - daemon re-reads the real data-root
   once the dataset is mounted
2. Delete orphaned duplicate bridges from the boot-race instance:
   `ip -br link | grep DOWN` -> `ip link del br-<id>` for each
3. Remove stale init containers pinning dead network ids:
   `docker rm -f <init-container>` then `docker compose up -d`

### Crowdsec LAPI Forbidden loop
1. `docker stop security-crowdsec`
2. Register the local machine into the DB using the yaml credentials:
   one-off container with both volumes:
   `cscli machines add localhost --password <yaml-password> --force`
3. `docker start security-crowdsec`

### CachyOS offline after reboot (no IP)
Cause: static IP applied live (`ip addr add`) is kernel-only; a reboot
forgets it, and NM had no wired profile on the bare switch.
Fix at console: `nmcli con add type ethernet con-name lan ifname <IFACE>
ipv4.method manual ipv4.addresses 192.168.1.191/24 ipv4.gateway
192.168.1.1 ipv4.dns "1.1.1.1 8.8.8.8" && nmcli con up lan`

### Monitoring stack rebuild after network surgery
`cd stacks/monitoring && docker compose up -d --force-recreate victoriametrics`
when VM loses network attachments. Stale `up == 0` series clear within
2 scrape intervals (~60s) after a healthy target reappears.

## Relocation checklist (validated on the interim gateway)
1. Router: reserve .3/.191 (same subnet = zero reconfig), forward
   TCP 443 + 2222 -> workstation IP
2. Gateway (workstation): sis-lan profile + sis-gateway.service auto-apply
3. Boot TrueNAS first (headscale control + B2 backups), then CachyOS
4. ddns updates headscale.wyattau.com within ~5 min
5. Verify: watchdog passes, `up == 0` empty, offsite metric non-zero
6. josh auto-reconnects once 443 is forwarded

## Appendix: CF tunnel is NOT viable for headscale control plane

Tested 2026-09-26: cloudflared tunnel + proxied CNAME for
headscale.wyattau.com. Health endpoint passed through the full chain,
and a raw HTTP/1.1 Upgrade request got 101 Switching Protocols.
However, a REAL tailscale client registration consistently failed:
Cloudflare's edge strips the TS2021 upgrade headers from tailscaled's
POST /ts2021 (a non-standard WebSocket-style upgrade that CF's
http/2-to-http/1.1 translation does not preserve). Headscale logged
"no upgrade header in TS2021 request" and returned 500. Verified with
a throwaway tailscale container dialing through the tunnel.

Conclusion: headscale control plane cannot ride a CF tunnel. It
requires a direct TCP path (port-forward or VPS proxy). The tunnel
ingress was removed and DNS reverted to the direct A record.
