# SimpleInfrastructureStack -- Operator Onboarding Guide

Quick-reference guide for a second operator to understand and manage this infrastructure.

---

## Repository Structure

```text
stacks/              Docker Compose definitions (20 stacks)
terraform/            Cloudflare DNS, Keycloak identity, Forgejo orgs
ansible/              Playbooks, roles, inventory
policies/             OPA/Conftest security policies (security.rego)
scripts/              Helper scripts (tf.sh, zfs-metrics.sh, etc.)
secrets/              SOPS age-encrypted environment files
docs/                 User-facing documentation
.github/workflows/     CI/CD pipelines (validate, deploy, scan, renovate)
```

## Adding a New Stack

1. Create `stacks/<name>/docker-compose.yml` with `${VAR}` references
2. Create `stacks/<name>/versions.env` with pinned image versions
3. Create `secrets/<name>.env.encrypted` with `sops -e`
4. Add stack name to the `stacks:` list in `ansible/inventory/group_vars/all.yml`
5. Add DNS record to `terraform/cloudflare.tf` `active_services` map (if public)
6. Add Traefik labels with `keycloak-auth` middleware (if SSO-protected)
7. Commit and push -- webhook triggers deploy

## Updating a Secret

1. Decrypt: `sops -d --input-type dotenv --output-type dotenv secrets/<stack>.env.encrypted`
2. Edit the value
3. Re-encrypt: `sops -e --input-type dotenv --output-type dotenv --in-place secrets/<stack>.env.encrypted`
4. Commit and push

## Running Diagnostics

```bash
# Container health
ssh truenas_admin@192.168.1.3 "sudo docker ps --format 'table {{.Names}}\t{{.Status}}' | sort"

# Alert status
docker exec operations-forgejo curl -s \
  'http://monitoring-victoriametrics:8428/api/v1/query?query=ALERTS%7Balertstate%3D%22firing%22%7D'

# Logs
docker exec operations-forgejo curl -s \
  'http://monitoring-victorialogs:9428/select/logsql/query' \
  -d 'query=_time:30m'
```

## Troubleshooting a Failed Deploy

1. Check deploy log: `tail -100 /var/log/infra-deploy.log`
2. Identify which stack failed from the Ansible output
3. Fix the issue, commit, and push (triggers redeploy)
4. If the fix requires secrets changes, update the encrypted file first

## Emergency Procedures

| Scenario | Action | Time |
|----------|--------|------|
| All services down | SSH to server, manual `docker compose up -d` | 5 min |
| Single stack failed | Fix compose, push, auto-redeploy | 10 min |
| Keycloak SSO broken | Check Keycloak logs, verify realm export | 15 min |
| Backup failed | Check Restic locks, verify storage | 15 min |
| Deploy webhook broken | SSH, manual deploy via `deploy.sh` | 5 min |

## Key Contacts

| Role | Responsibility |
|------|-------------|
| Primary | All infrastructure, secrets, Terraform state |
| Backup | Restic verification, B2 sync, DR drills |
| Monitoring | Alert tuning, dashboard maintenance, log queries |

## Emergency Access

```bash
# SSH via Cloudflare Tunnel
ssh -o ProxyCommand="cloudflared access ssh --hostname ssh.wyattau.com" truenas_admin@192.168.1.3

# Manual deploy
ssh truenas_admin@192.168.1.3
sudo docker exec infra-webhook bash /opt/webhook/deploy.sh
```
