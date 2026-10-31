  │     ├── TrueNAS (192.168.1.3); 96TB ZFS pool
  │     ├── CachyOS (192.168.1.191); CI runner server
        ├── truenas-1 (100.64.0.2); exit node
## TrueNAS (192.168.1.3): ~42 Containers
## CachyOS (192.168.1.191): CI Runners
│  │ docker-init (tini); PID 0           │  │
Monthly automated restore test runs in backup-cron-trigger (needs bash in image; fixed Sep 2026).