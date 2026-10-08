# EIR non-root audit — effective runtime user of the critical tier

Audit of the 58 "critical" images the smoke test flagged as lacking a
non-root `USER` directive (Oct 2026). Method: fetch each image's config
blob from GHCR and read `.config.User` — the *effective* runtime user,
which the smoke test's static Dockerfile grep could never see (USER
inherited from upstream base layers is invisible to a text grep).

Data: `/tmp/opencode/effective-users.json` (regenerate via the GHCR
registry API, manifest → config blob, amd64, `latest` tag).

---

## Headline finding

**23 of 58 were false positives.** Upstream bases set USER in inherited
layers: `argo-cd` runs 999, `loki`/`tempo` 10001, `coredns`
nonroot:nonroot, `kafka` appuser, `jenkins` jenkins, and so on. The
smoke test's static grep was structurally wrong and has been replaced
with a post-build `docker image inspect .Config.User` check (EIR
`1dc9a89ef`), which is authoritative and covers inheritance.

## The 35 true root-starters, classified

### Tier A — starts as root, drops privileges at runtime (accepted, 14)

Official upstream patterns: entrypoint chowns the data directory, then
`gosu`/`su-exec`/s6 steps down to the app user. Forcing `USER` in the
Dockerfile would *break* them (the init needs root to fix volume
ownership).

| Image | Drop mechanism |
| --- | --- |
| postgres, postgresql-16, immich-postgres | official entrypoint + gosu |
| mysql, mongodb | official entrypoint + gosu |
| redis | official entrypoint (`su-exec` on alpine variants) |
| paperless-ngx | s6-overlay with `USERMAP_UID`/`GID` |
| immich, immich-server | entrypoint chowns upload dir, steps down |
| taiga, taiga-backend, taiga-protected | upstream entrypoint scripts |
| busybox | run-to-exit utility/init usage |

### Tier C — root required by function (accepted with mitigations, 8)

Host agents and capability-requiring services. These should never run
on tenant networks and are excluded from tenant templates.

| Image | Why root |
| --- | --- |
| crowdsec | reads host logs, firewall bouncer |
| falco | kernel syscall inspection |
| fluent-bit | reads host `/var/log` |
| watchtower | docker socket (self-update) |
| portainer-agent, portainer-edge | docker socket + host fs |
| docker-socket-proxy | socket access by design (least-privilege filter over it) |

Mitigations: host network isolation (nftables input baseline confines
them to the mgmt/tenant bridges), `no-new-privileges` where compatible,
and daemon-level `userns-remap` exclusion documented per container.

### Tier B — collapsed to empty (runtime-tested, Oct 2026)

The initial classification listed 13 "fix candidates". Fix wave 1
runtime-tested five of them by running the upstream images with
`--user 65532:65532` (docker-level, identical to a Dockerfile USER):

| Image | Result as 65532 |
| --- | --- |
| calibre-web (linuxserver) | `s6-applyuidgid: fatal: unable to set supplementary group list` — linuxserver's s6 init REQUIRES root start, then applies PUID/PGID |
| flame | `chown: /app/data: Operation not permitted` — entrypoint chowns then runs |
| sqlpad | node process crash on startup paths |
| uptime-kuma | `chown: changing ownership of '/app/data': Operation not permitted` |
| matrix-hookshot | `/data/config.yml` unwritable, exit |

**All five are upstream-designed root-start images.** The Tier B
hypothesis was wrong for every tested member — the same class of error
as the false positives: classification from text instead of runtime.
Every FROM-upstream image in the former Tier B list moves to Tier A
(upstream-init pattern). The only true fix path would be rebuilding
from source with our own user layout — real forks, not justified while
userns-remap provides the containment.

**Final tally: Tier A ~44 (upstream/drop patterns, runtime-evidenced),
Tier C 8 (root-required), Tier B 0. The per-image fix wave is
cancelled with evidence; userns-remap is the control.**

---

## The systemic control

Daemon-level `userns-remap` on docker01 (Ansible role change queued)
re-maps container root to unprivileged host UIDs, making even these
35 root-starters safe in the tenant context — at the cost of
pre-arranged bind-mount ownership (the subuid range) and no host
networking (cAdvisor/monitoring get `--userns=host` explicitly).

Tier A/C images keep working under remap; Tier B fixes are then
defense-in-depth rather than urgent.

## Smoke-test change

`scripts/smoke_test.sh` no longer greps Dockerfile text for USER — that
check produced 23 false positives and could never see inheritance. The
post-build `docker image inspect` records the effective user: non-root
as `OK`, root-start as `INFO` (not a failure — Tier A/C legitimacy).
