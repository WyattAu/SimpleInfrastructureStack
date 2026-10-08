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

### Tier B — no reason to be root (fix candidates, 13)

| Image | Note |
| --- | --- |
| calibre-web | python app; add USER + chown in build |
| cockroachdb | Go binary; upstream supports non-root with `--store` path writable |
| drone | Go binary; binds 80/443 by default — needs port override or cap |
| envoy | upstream contributes a non-root variant; set USER 65532 + ensure 8080/9901 |
| flame | static dashboard; trivial |
| immich-machine-learning | python; upstream runs as root, writable /cache needed |
| kanidm, kanidm-client, kanidm-server | upstream packages usually drop to `kanidmd`; verify our build's entrypoint |
| matrix-hookshot | node app; trivial |
| rabbitmq | config shows root; official entrypoint gosu's down — reclassify after runtime check |
| scylla-operator | Go binary |
| sqlpad | node app; trivial |
| trivy | Go binary |
| typesense | C++ binary; data dir writable by 65532 |
| uptime-kuma | node app; needs writable /data |
| vault | hashicorp official entrypoint drops to vault — likely Tier A after runtime check |

Remediation order: runtime-verify each (run with `id -u`, check the
port bindings), add `USER 65532:65532` + build-time `chown` for the
writable paths, smoke test already validates start + health post-change.
**Do not batch-fix blind**: the loop's own standard is one verified
wave, and `userns-remap` on the hosting host is the systemic control
that covers all of them meanwhile (see below).

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
