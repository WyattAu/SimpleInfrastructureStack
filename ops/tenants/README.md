# Customer tenants

Per-tenant stacks for paying customers. Each tenant gets an isolated stack —
its own database, its own data directory, its own credentials — provisioned
from a template in this directory.

Everything here is intentionally decoupled from the internal infrastructure:
no shared Postgres, no shared Redis, no shared identity provider. A customer
tenant must never be able to reach our internal network, and an internal
outage must not take a paying customer's service down.

## Layout

```text
ops/tenants/
├── README.md                    # this file
└── templates/
    ├── documents/               # Paperless-ngx  — document management
    ├── files/                   # Ferro          — file storage (our Rust product)
    └── photos/                  # Immich         — photo library
```

Each template holds three files:

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | the stack, with resource limits and `sis.tenant` labels |
| `versions.env` | pinned image versions (Renovate-updatable) |
| `env.template` | credential/identity placeholders filled by the provisioner |

## Provisioning a tenant

```bash
export TENANT_ROOT=/srv/tenants          # default
./ops/tenant-provision.sh acme documents --domain docs.acme.example
```

The provisioner generates a unique Postgres password, Redis password, app
secret key and admin password; writes `.env` (chmod 600) and `.credentials`;
creates the data directory; generates a `compose.sh` wrapper; and starts the
stack.

Useful flags: `--no-start` (prepare only), `--force` (regenerate `.env`,
which **rotates credentials**), `--port` (override the auto-picked port),
`--admin-user`.

### Always use `compose.sh`

`docker compose` only auto-loads `.env`, so image pins in `versions.env` would
silently resolve to empty tags (`.../postgres:`). Each tenant directory gets a
`compose.sh` that passes both files in the correct order:

```bash
/srv/tenants/acme/compose.sh up -d
/srv/tenants/acme/compose.sh ps
/srv/tenants/acme/compose.sh logs --tail 100
```

## Ports

Tenants publish on `127.0.0.1` only, starting from `PORT_BASE` (18080), and
the first free port is chosen automatically. TLS is terminated at the shared
edge proxy.

## Edge proxy

Add a router per tenant to the proxy configuration, then reload. Traefik
(static file provider) example:

```text
http://127.0.0.1:<PORT> →
  host: docs.acme.example
  tls: { certResolver: cloudflare }
```

Caddy equivalent:

```text
docs.acme.example {
    reverse_proxy 127.0.0.1:<PORT>
}
```

Do **not** attach the internal `keycloak-auth@file` middleware to customer
tenants — customers authenticate against their own accounts.

## Backup

```bash
./ops/tenant-backup.sh acme              # snapshot to the live restic repo
./ops/tenant-backup.sh acme --offsite    # ...and copy to B2
./ops/tenant-backup.sh acme --list       # snapshots tagged for this tenant
./ops/tenant-backup.sh acme --restore <snapshot-id>
```

The backup script stops the stack first: a file-level copy of a live database
is not a backup you can trust. Expect a short outage per backup window.

Snapshots are tagged `tenant:<slug>` inside the existing restic repository, so
there is one credential set to manage while still allowing per-tenant restore
or export. `TENANT_PRUNE=1` applies the shared retention policy — note that
forget/prune affects **all** snapshots in the repo, not just this tenant.

Per-tenant repository or key (if a contract demands it):

```bash
restic init --repository /path/to/tenant-repo
export TENANT_RESTIC_REPO=/path/to/tenant-repo   # tenant-backup.sh honours this
```

### Scheduling

Add one systemd unit or cron entry per tenant rather than looping in a single
script, so a single failure is visible on its own:

```cron
30 4 * * *  TENANT_ROOT=/srv/tenants /opt/sis/ops/tenant-backup.sh acme --offsite
```

## Pilot readiness

Honest status per service — do not sell a template before validating it.

| Template | Status | Notes |
| --- | --- | --- |
| `documents` | **pilot-ready** | Same stack as our own production `stacks/documents`. Pattern proven in production for months. |
| `files` | needs auth wiring | Ferro is our own product and runs in production, but expects an OIDC issuer. Decide per tenant whether it uses the customer's IdP or the edge proxy's auth. |
| `photos` | validate first | Immich images exist in EIR but we have not run this stack ourselves yet. Stand up a staging tenant before onboarding a customer. |

## Capacity

Per-tenant limits are set in each template (`cpus`, `memory`, `pids`).
Indicative headroom for a 16-core / 128GB EPYC host:

| Tenants | Profile |
| --- | --- |
| 10 | comfortable, ML enabled, room for growth |
| 25 | typical small-business mix (`documents`/`files`) |
| 40 | tight — watch memory, most `documents` tenants want 2G |
| 50+ | add a second host, or move heavy tenants to dedicated resource reservations |

## Adding a template

1. Create `templates/<service>/` with the three files.
2. Pin versions in `versions.env` and verify every tag exists in GHCR.
3. Placeholders must come from `env.template` and be substituted by
   `ops/tenant-provision.sh` (`__TENANT__`, `__DOMAIN__`, `__TZ__`,
   `__TENANT_DATA_DIR__`, `__APP_PORT__`, `__POSTGRES_PASSWORD__`,
   `__REDIS_PASSWORD__`, `__PAPERLESS_SECRET_KEY__`, `__ADMIN_USER__`,
   `__ADMIN_PASSWORD__`).
4. Label every service `sis.tenant=${TENANT}` and `sis.service=<service>`.
5. Validate before use: `docker compose --env-file .env --env-file versions.env config`.
6. Add it to the pilot-readiness table above with an honest status.
