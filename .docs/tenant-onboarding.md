# Tenant onboarding and handover

Runbook for taking a customer from "signed up" to "using it", and for handing
the service over so they can self-serve. Target: first working login within one
working day of provisioning.

Operator scripts referenced here live in `ops/`.

---

## Before provisioning

Confirm these, or the launch will stall on someone else's DNS:

- [ ] Signed agreement or paid invoice
- [ ] Domain confirmed, and who controls the DNS zone
- [ ] Named technical contact who can make DNS changes during the window
- [ ] Service agreed, and the template marked pilot-ready in `ops/tenants/README.md`
- [ ] Whether they want the `files` auth wired to their IdP or to our edge proxy

---

## Provision

```bash
export TENANT_ROOT=/srv/tenants
./ops/tenant-provision.sh <tenant> <service> --domain <fqdn>
```

Record from the output:

- tenant slug and directory
- hostname
- local port
- initial admin username and password (also in `<tenant>/.credentials`, chmod 600)

`--no-start` prepares without starting; `--force` on an existing tenant
**rotates every credential** and requires `compose.sh up -d --force-recreate`.

## DNS

Ask the customer for a TXT record and verify it before they create the record:

```bash
dig TXT <token>._domainkey.<their-domain>
```

Then, at their DNS provider:

| Field | Value |
| --- | --- |
| Type | A |
| Name | `<fqdn>` (e.g. `docs`) |
| Content | this host's public IPv4 |
| Proxy | DNS only, unless TLS is terminated at Cloudflare (see below) |
| TTL | 300 during setup, raise to 3600+ after launch |

If we terminate TLS at Cloudflare instead, use a proxied CNAME to the tunnel
hostname and keep the origin certificate in mind — do not leave the origin
open on :80/:443 (origin certificate mismatch).

Verify from outside the host, not from the host:

```bash
dig +short <fqdn>          # must not be 127.0.0.1 or a private range
curl -fsS https://<fqdn>/  # after the proxy step
```

## Reverse proxy

Add a router to the edge proxy config (snippets in `ops/tenants/README.md`),
then reload it and confirm the route took effect:

```bash
/srv/tenants/<tenant>/compose.sh ps
curl -fsS http://127.0.0.1:<port>/ >/dev/null && echo "origin healthy"
```

Do not attach internal auth middleware (for example `keycloak-auth@file`) to a
customer tenant.

## Backup

```bash
./ops/tenant-backup.sh <tenant> --offsite          # take the first snapshot
./ops/tenant-backup.sh <tenant> --list             # confirm it is tagged
```

Then schedule it (one unit per tenant — see `ops/tenants/README.md`).

**Before handover, prove a restore works on this template.** A backup that has
never been restored is not a backup:

```bash
./ops/tenant-backup.sh <tenant> --restore <snapshot-id>
```

## Handover session

Send these in advance, in writing:

- URL and the initial credentials, changed on first login
- Where their data lives and how it is backed up (nightly, plus off-site)
- The maintenance window for backups (the stack stops briefly)
- Support contact and response expectation
- What "best effort, no uptime guarantee" means in practice

Walk them through:

1. **Rotate the initial admin password.** Never let a customer keep a password
   we generated and stored.
2. **Create named accounts** for each user; do not share the admin account.
3. **Turn on MFA** where the software supports it.
4. **Set their timezone and locale** so dates are not confusing.
5. **Explain the backup window** and that a restore is on request.
6. **Show them how to get their data out** — see below.

Then close with: what is included, what would cost extra (storage, users,
custom work), and how to cancel.

## Exit

Exit must be easy and rehearsed — it is the main thing distinguishing us from a
platform that holds data hostage.

```bash
./ops/tenant-backup.sh <tenant> --list                     # find the snapshot
RESTIC_REPOSITORY=... restic export <snapshot-id> > <tenant>-export.tar
```

Offer a live dump of the application data too (database dump plus the data
directory), in open formats. Then:

```bash
/srv/tenants/<tenant>/compose.sh down          # stop containers, keep data
# once the customer confirms they have everything:
rm -rf /srv/tenants/<tenant>                   # only after explicit confirmation
```

Give the customer their database dump and the export archive, confirm receipt,
then delete. Keep a copy of the restore test in your own records.

---

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Provision fails: port in use | `ss -ltnp \| grep <port>`; pass `--port` |
| Containers healthy, URL 502 | Proxy route not added, or pointing at the wrong port |
| DNS resolves to 127.0.0.1 | Wrong record, or split-horizon DNS; check from outside |
| TLS error | Certificate not issued yet, or origin exposed without the origin cert |
| App healthy but login loops | Proxy not forwarding `X-Forwarded-Proto`/host correctly |
| Restore fails | Tenant stopped mid-backup; check `.credentials` and the snapshot list |
| Disk filling | Check tenant quota and the off-site copy cadence |

Service-specific first-run steps (for example creating an ERPNext site) belong
in the template's own `NOTES.md`, not here.
