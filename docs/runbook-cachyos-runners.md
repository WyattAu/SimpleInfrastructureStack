# CachyOS Forgejo Runner Runbook

> Forgejo CI runners on CachyOS (192.168.1.191) managed via Ansible.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  CachyOS Host (192.168.1.191)                                   │
│                                                                 │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  forgejo-runner@general.service                            │  │
│  │  ┌──────────────────────────────────────────────────────┐  │  │
│  │  │  runner-daemon:2.0.0 container                       │  │  │
│  │  │  ┌────────────────┐  ┌────────────────┐              │  │  │
│  │  │  │ ubuntu:24.04   │  │ node:1.0.0     │  ...         │  │  │
│  │  │  │ (work container)│  │ (work container)│              │  │  │
│  │  │  └────────────────┘  └────────────────┘              │  │  │
│  │  └──────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  forgejo-runner@peptide-web.service                        │  │
│  │  ┌──────────────────────────────────────────────────────┐  │  │
│  │  │  runner-daemon:2.0.0 container                       │  │  │
│  │  │  ┌────────────────┐  ┌────────────────┐              │  │  │
│  │  │  │ ubuntu:24.04   │  │ node:1.0.0     │  ...         │  │  │
│  │  │  └────────────────┘  └────────────────┘              │  │  │
│  │  └──────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  forgejo-runner@questhive.service                          │  │
│  │  ┌──────────────────────────────────────────────────────┐  │  │
│  │  │  runner-daemon:2.0.0 container                       │  │  │
│  │  │  ┌────────────────┐  ┌────────────────┐              │  │  │
│  │  │  │ ubuntu:24.04   │  │ node:1.0.0     │  ...         │  │  │
│  │  │  └────────────────┘  └────────────────┘              │  │  │
│  │  └──────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

Each runner follows the **daemon + work containers** pattern:

1. **runner-daemon** (`runner-daemon:2.0.0`) — Long-running container that holds the `.runner` registration file and communicates with Forgejo. It receives job assignments and spawns work containers.
2. **Work containers** — Ephemeral containers (e.g., `ubuntu:24.04`, `node:1.0.0`) created by the daemon for each CI job. Destroyed when the job finishes.

### File Layout

```
/opt/forgejo-runners/
├── general/
│   ├── daemon.yml          # Daemon config (labels → images)
│   ├── .runner             # Registration token (created via forgejo-runner register)
│   └── cache/              # Persistent job cache
├── peptide-web/
│   ├── daemon.yml
│   ├── .runner
│   └── cache/
└── questhive/
    ├── daemon.yml
    ├── .runner
    └── cache/
```

### Systemd

```
/etc/systemd/system/forgejo-runner@.service   # Template unit
forgejo-runner@general.service                # Instance for "general"
forgejo-runner@peptide-web.service            # Instance for "peptide-web"
forgejo-runner@questhive.service              # Instance for "questhive"
```

## Common Operations

### Check Runner Status

```bash
# All runners
systemctl status 'forgejo-runner@*'

# Single runner
systemctl status forgejo-runner@general

# Logs
journalctl -u forgejo-runner@general -f --no-pager
```

### Restart a Runner

```bash
systemctl restart forgejo-runner@general
```

### View Runner Container

```bash
docker ps --filter name=forgejo-runner-general
docker logs forgejo-runner-general --tail 100
```

### Check Work Containers

```bash
# List active work containers spawned by a runner
docker ps --filter label=runner=general
```

## Adding a New Runner

### 1. Update Ansible Defaults

Edit `ansible/roles/manage_runners/defaults/main.yml` and add to `forgejo_runner_runners`:

```yaml
forgejo_runner_runners:
  - name: my-new-runner
    labels:
      ubuntu-latest: docker://ghcr.io/wyattau/runner-images/ubuntu:24.04
      node: docker://ghcr.io/wyattau/runner-images/node:1.0.0
    capacity: 2
```

### 2. Deploy

```bash
ansible-playbook ansible/playbooks/site.yml --limit cachyos
```

Or deploy just the runner role:

```bash
ansible-playbook ansible/playbooks/site.yml --limit cachyos --tags manage_runners
```

### 3. Register with Forgejo

After the directory exists but before the service will work, you need to register:

```bash
# On the CachyOS host
cd /opt/forgejo-runners/my-new-runner
docker run --rm -it \
  -v $(pwd):/data \
  ghcr.io/wyattau/runner-images/runner-daemon:2.0.0 \
  register \
    --name my-new-runner \
    --instance http://192.168.1.3:3000 \
    --labels ubuntu-latest,node \
    --token <RUNNER_TOKEN_FROM_FORGEJO_UI>
```

This creates the `.runner` file. Then start the service:

```bash
systemctl enable --now forgejo-runner@my-new-runner
```

### 4. Verify

Check the Forgejo admin panel at `http://192.168.1.3:3000` → Site Administration → Actions → Runners.

## Updating the Daemon Image

The daemon image (`runner-daemon:2.0.0`) is what runs the forgejo-runner binary inside a container.

1. Update the tag in `ansible/roles/manage_runners/defaults/main.yml`:

```yaml
forgejo_runner_daemon_image: ghcr.io/wyattau/runner-images/runner-daemon:2.1.0
```

2. Deploy:

```bash
ansible-playbook ansible/playbooks/site.yml --limit cachyos --tags manage_runners
```

The handler will restart all runners, pulling the new image.

## Updating Work Container Images

Work images are defined per-label in `forgejo_runner_runners[].labels`. To update:

1. Change the image reference in `defaults/main.yml`:

```yaml
forgejo_runner_runners:
  - name: general
    labels:
      node: docker://ghcr.io/wyattau/runner-images/node:1.1.0  # bumped
```

2. Deploy — the daemon.yml will be re-templated. Existing running jobs finish with the old image; new jobs use the updated image.

No runner restart is strictly required since the daemon reads daemon.yml per-job, but the handler will restart anyway.

## Updating the systemd Unit

The systemd template is at `templates/forgejo-runner@.service.j2`. After editing:

```bash
ansible-playbook ansible/playbooks/site.yml --limit cachyos --tags manage_runners
```

This copies the new unit file and does `daemon_reload`.

## Troubleshooting

### Runner Won't Start

```bash
# Check service status
systemctl status forgejo-runner@general

# Check recent logs
journalctl -u forgejo-runner@general -n 50 --no-pager

# Common causes:
# - .runner file missing (not registered)
# - Docker socket not accessible
# - daemon.yml syntax error
```

### Stuck / Stale Tasks

If a runner shows jobs as "running" but nothing is happening:

```bash
# List work containers for this runner
docker ps --filter label=runner=general

# Force-remove stuck containers
docker rm -f $(docker ps -q --filter label=runner=general)

# Restart the runner
systemctl restart forgejo-runner@general
```

### Capacity Issues

If Forgejo shows the runner as "busy" but no jobs are running:

1. Check the runner's capacity in `daemon.yml` vs. configured in Forgejo admin panel.
2. The `capacity` field in defaults controls how many concurrent jobs the daemon will accept.
3. If stuck, restart: `systemctl restart forgejo-runner@general`

### Docker "task not found" Errors

This usually means the work container was removed externally (e.g., `docker rm`, Docker daemon restart):

```bash
# Check Docker daemon
systemctl status docker

# Check for orphaned containers
docker ps -a --filter status=exited

# Clean up
docker container prune -f

# Restart the affected runner
systemctl restart forgejo-runner@general
```

### Permission Denied on Docker Socket

The daemon container runs as UID 65532 with the docker group (GID 956). Verify:

```bash
# Check docker group GID on host
getent group docker

# Ensure the daemon.yml runner config matches
# (should be GID 956 on CachyOS)
```

### Ghost Tasks in Forgejo

Sometimes Forgejo shows phantom running tasks that no longer exist. Clean them via the Forgejo database:

```bash
# Connect to Forgejo's PostgreSQL database
docker exec -it operations-postgres-forgejo psql -U forgejo -d forgejo

# Find stale action runs
SELECT id, status, runner_id FROM action_run WHERE status = 'running';

# Mark them as failed/cancelled
UPDATE action_run SET status = 'failed' WHERE status = 'running' AND id < <STALE_ID>;
```

Or via the Forgejo admin API:

```bash
# Cancel a stuck run
curl -X POST \
  -H "Authorization: token <FORGEJO_ADMIN_TOKEN>" \
  http://192.168.1.3:3000/api/v1/admin/runners/<RUNNER_ID>/tasks/<TASK_ID>/cancel
```

## Ansible Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `forgejo_runner_base_path` | `/opt/forgejo-runners` | Root directory for all runners |
| `forgejo_runner_daemon_image` | `ghcr.io/wyattau/runner-images/runner-daemon:2.0.0` | Runner daemon container image |
| `forgejo_runner_work_image` | `ghcr.io/wyattau/runner-images/node:1.0.0` | Default work container image |
| `forgejo_runner_user_uid` | `65532` | UID for the daemon process inside container |
| `forgejo_runner_docker_gid` | `956` | Docker group GID on CachyOS host |
| `forgejo_runner_forgejo_url` | `http://192.168.1.3:3000` | Forgejo instance URL |
| `forgejo_runner_capacity` | `4` | Default concurrent job capacity |
| `forgejo_runner_timeout` | `3h0m0s` | Job execution timeout |
| `forgejo_runner_update_timeout` | `1h0m0s` | Job update timeout |
| `forgejo_runner_log_level` | `info` | Daemon log level (debug, info, warn, error) |
| `forgejo_runner_runners` | (list of 3) | Runner definitions with name, labels, capacity |
