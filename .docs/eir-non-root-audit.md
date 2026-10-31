# EIR non-root audit: effective runtime user of the critical tier
blob from GHCR and read `.config.User`; the *effective* runtime user,
### Tier A: starts as root, drops privileges at runtime (accepted, 14)
### Tier C: root required by function (accepted with mitigations, 8)
### Tier B: collapsed to empty (runtime-tested, Oct 2026)
| calibre-web (linuxserver) | `s6-applyuidgid: fatal: unable to set supplementary group list`; linuxserver's s6 init REQUIRES root start, then applies PUID/PGID |
| flame | `chown: /app/data: Operation not permitted`; entrypoint chowns then runs |
hypothesis was wrong for every tested member; the same class of error
from source with our own user layout; real forks, not justified while
35 root-starters safe in the tenant context; at the cost of
`scripts/smoke_test.sh` no longer greps Dockerfile text for USER; that
as `OK`, root-start as `INFO` (not a failure; Tier A/C legitimacy).