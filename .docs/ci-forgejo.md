# CI on Forgejo (self-hosted)

**Status: CURRENT (2026-11-14).** Private-repo CI runs on the estate's own
Forgejo, not GitHub. GitHub Actions minutes were the binding constraint, and
an account payment-state block stalled the core services' verification for two
weeks. Self-hosted runners are free and unlimited for private repos.

## Topology

| Piece | Where | Detail |
| --- | --- | --- |
| Forgejo | NAS, `http://192.168.1.3:3000` (`https://git.wyattau.com`) | 15.0.4, Actions enabled |
| Runner | NAS, container `forgejo-runner` | `code.forgejo.org/forgejo/runner:6`, host network, docker socket |
| Runner name / label | `nas-sis-rust` / `sis-rust` | **unique label** so it never picks up other repos' jobs |
| Job image | `sis-ci-rust:1` | Rust 1 + Node 20 + rustfmt + clippy (see `ops/ci/runner-image/Dockerfile`) |
| Cargo cache | `/mnt/pool_HDD_x2/tank/datasources/sis/appdata/runner-cache` → `/cache` | `CARGO_HOME=/cache/cargo`, `CARGO_TARGET_DIR=/cache/target` |

Repos migrated: `wyatt_admin/flagsd`, `wyatt_admin/authbox`,
`wyatt_admin/eventbusd`.

## Why a custom image

The stock `rust:*` image has **no `node`**, and `actions/checkout@v4` is a Node
action — the job dies at step 1 with `exec: "node": executable file not found
in $PATH` (exit 126). `sis-ci-rust:1` adds Node 20 and pre-installs
rustfmt/clippy, so no per-job toolchain install.

```sh
docker build -t sis-ci-rust:1 ops/ci/runner-image
```

## Register a runner

```sh
TOKEN=$(curl -s -H "Authorization: token $FORGEJO_API" \
  http://192.168.1.3:3000/api/v1/admin/actions/runners/registration-token \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')

docker run --rm --user root \
  -v /path/to/forgejo-runner:/data \
  code.forgejo.org/forgejo/runner:6 \
  forgejo-runner register --no-interactive \
    --instance http://192.168.1.3:3000 --token "$TOKEN" \
    --name nas-sis-rust --labels "sis-rust:docker://sis-ci-rust:1"
```

Then `config.yml`:

```yaml
runner:
  capacity: 1
  labels:
    - "sis-rust:docker://sis-ci-rust:1"
cache:
  enabled: true
  dir: /data/cache
container:
  network: host
  valid_volumes:
    - /mnt/pool_HDD_x2/tank/datasources/sis/appdata/runner-cache
  options: "-v /mnt/pool_HDD_x2/tank/datasources/sis/appdata/runner-cache:/cache"
```

Jobs set `CARGO_HOME=/cache/cargo` and `CARGO_TARGET_DIR=/cache/target`.
Measured on the 4-core NAS: a cold flagsd gate takes ~2.5–4 min; a warm
gate (registry + deps cached) runs in ~35 s.

Run it:

```sh
docker run -d --name forgejo-runner --restart unless-stopped --user root \
  --network host \
  -v /path/to/forgejo-runner:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  code.forgejo.org/forgejo/runner:6 \
  forgejo-runner daemon --config /data/config.yml
```

## The workflow contract

`.forgejo/workflows/quality.yml` mirrors the tier-b `rust-kit` gate:
fmt, check (all-features and no-default-features), clippy `-D warnings`, tests,
doctests. It is self-contained — Forgejo cannot resolve a cross-instance
`uses: owner/repo/.github/workflows/x.yml@main`.

## Gotchas (each cost a failed run)

1. **`config.yml` labels override the registered labels.** Editing `.runner`
   or re-registering is not enough; the image comes from `config.yml`.
2. **Forgejo executes `.github/workflows` too.** The GitHub reusable-workflow
   gate fails there with an unresolvable `uses:`; delete those files when a
   repo moves to Forgejo (or keep them and accept red runs).
3. **Run the runner as root** — it writes `.runner` in `/data` and talks to
   `/var/run/docker.sock`.
4. **Never register with generic labels** (`docker`, `ubuntu`) at instance
   level: the runner will pick up other users' repos (observed: a Rankhub job
   claimed within seconds). Use a project-specific label.
5. The runner API is `/api/v1/admin/actions/runners` (the `/admin/runners`
   path 404s on 15.0.4).
6. **In forgejo-runner v6, the `container.volumes` block is dead config.**
   `internal/app/run/runner.go` passes `ValidVolumes` to the act library but
   never forwards `cfg.Container.Volumes`, so host mounts declared there are
   silently dropped — jobs then rebuild everything into an ephemeral
   container layer (runs stay green, so nothing surfaces the loss except the
   cache dir staying at 512 B). Declare the bind through `container.options`
   and whitelist its source in `container.valid_volumes`; the act sanitizer
   strips any bind whose source is not whitelisted. The "not a valid volume"
   warning goes to the job log, not the runner daemon log.

## Moving to the new server

Everything above is host-agnostic. On the new box: build
`ops/ci/runner-image`, create the data dir, register with the same label,
mount a local cargo cache. Then retire the NAS runner by deleting it in the
admin runner list (`DELETE /api/v1/admin/actions/runners/{id}`).
