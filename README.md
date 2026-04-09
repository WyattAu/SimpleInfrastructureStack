# SimpleInfrastructureStack

Simple infrastructure stack for personal usage, with defense-in-depth security, resource governance, and observability.

## Architecture Overview

The stack runs on a single TrueNAS SCALE host and consists of 9 Docker Compose stacks behind a Traefik reverse proxy with centralized Keycloak SSO.

```
Internet
  │
  ▼
Cloudflare DNS (DDNS + Proxy)
  │
  ▼
TrueNAS SCALE Host
  ├── Port 80/443 ──▶ Traefik ──▶ [security-headers] ──▶ Services
  │                    │
  │                    ├── OAuth2-Proxy ──▶ Keycloak (OIDC)
  │                    │
  │                    └── Socket-Proxy ──▶ Docker API (restricted)
  │
  ├── [traefik_net]  Public-facing services (Traefik labels)
  ├── [backend_net]  Internal service communication (databases, monitoring)
  └── [ci_net]       Isolated CI workloads (Docker-in-Docker)
```

### Security Measures

| Layer | Implementation |
|-------|---------------|
| TLS | Automatic Let's Encrypt via Cloudflare DNS-01 challenge |
| Authentication | Centralized Keycloak SSO via OAuth2-Proxy forward auth |
| Security Headers | HSTS (1 year), XSS protection, nosniff, frame-deny, CSP, referrer-policy |
| Container Isolation | `no-new-privileges:true` on all services, `read_only` filesystems where possible |
| Network Segmentation | 3 isolated networks: public, internal, CI |
| CI Isolation | Docker-in-Docker on dedicated `ci_net`, not shared with backend |
| Brute-Force Protection | Keycloak locks after 5 failed attempts |
| Image Integrity | All images pinned to specific versions (no `:latest` tags) |
| Log Integrity | Loki authentication required for log push |

### Stacks

| Stack | Services | Purpose |
|-------|----------|---------|
| `proxy` | Traefik, OAuth2-Proxy, Cloudflare DDNS, Socket-Proxy | Gateway, TLS, SSO |
| `iam` | Keycloak, PostgreSQL | Identity management |
| `operations` | Forgejo, Woodpecker CI, Docker-in-Docker, PostgreSQL | Git hosting, CI/CD |
| `collaboration` | Synapse, Element Web, Matrix Hookshot, PostgreSQL | Chat, Matrix |
| `storage` | oCIS, Collabora Online, PostgreSQL | File storage, document editing |
| `monitoring` | Prometheus, Grafana, Loki, Promtail, Uptime Kuma, cAdvisor, Node Exporter | Metrics, logs, uptime |
| `utility` | Homepage | Personal dashboard portal |
| `accounting` | Akaunting, PostgreSQL | Self-hosted accounting |
| `backup` | Restic, Cron Trigger | Automated backups |

## Infrastructure Tooling

### Makefile Targets

```bash
make install-hooks    # Install pre-commit hooks
make lint             # Run all pre-commit checks
make check-policies   # Run OPA/Conftest security policies against compose files
make check-images     # Verify all Docker images are pinned (no :latest)
make check-env-examples  # Verify all stacks have .env.example files
make security-audit   # Run all security checks (policies + images + env examples)
make terraform-plan   # Show Terraform execution plan
make terraform-apply  # Apply Terraform infrastructure changes
```

### OPA/Conftest Policies

Security policies in `policies/docker-compose/security.rego` enforce:
- No `privileged: true` (except Docker-in-Docker)
- `no-new-privileges:true` on all services
- No `:latest` image tags
- Resource limits on all stateful services
- Logging configured on all services
- No read-write Docker socket mounts to sensitive paths

### Terraform

Terraform manages Docker networks declaratively:

```bash
cd terraform
terraform init
terraform plan    # Preview changes
terraform apply   # Create/update networks
```

### Prometheus Alerting

Pre-configured alert rules in `monitoring/prometheus/alert_rules.yml` cover:
- Container OOM kills and high memory/CPU usage
- Container restart loops and downed containers
- Host memory, disk, and inode exhaustion
- PostgreSQL connectivity and connection saturation
- Traefik 5xx error rate spikes

---

## Implementation Procedure

Prerequisites:

- All files from the final, definitive set are committed and pushed to a private GitHub repository.
- You have shell (SSH) access to the TrueNAS SCALE host.
- You have administrator access to the Portainer UI.

### Phase 0: Host and System Preparation (One-Time Setup)

Objective: To prepare the TrueNAS host with the foundational users, directories, and networks required by all subsequent stacks.

Procedure:

1. Create ZFS Datasets:

   - In the TrueNAS UI, navigate to Datasets.
   - Create the parent dataset for all application configurations and data: `/mnt/mainpool/apps`.
   - Under `/mnt/mainpool/apps`, create the primary data volume dataset: `data`.
   - Under `/mnt/mainpool/apps`, create the primary backup dataset: `backups`.
   - Under `/mnt/mainpool/apps/data`, create the following child datasets: `proxy`, `iam`, `operations`, `collaboration`, `monitoring`, `storage`, `utility`.

2. Create Dedicated User:

   - In the TrueNAS UI, navigate to Credentials → Local Users.
   - Create a new user named `docker-apps`.
   - Set the User ID (UID) and Primary Group ID (GID) to `1001`.
   - Disable password login for this user.

3. Set Data Permissions:

   - Navigate back to the `/mnt/mainpool/apps` dataset.
   - Edit its permissions, select the `docker-apps` user, and grant it `Read`, `Write`, and `Execute` access.
   - Ensure the permission changes are applied recursively to all child datasets.

4. Create Shared Docker Networks:

   - SSH into your TrueNAS host.
   - Execute the following commands:

     ```bash
     docker network create traefik_net
     docker network create backend_net
     docker network create ci_net
     ```

   > Alternatively, use Terraform: `cd terraform && terraform apply`

5. Generate Required Secrets:

   ```bash
   # Loki password for log authentication
   python3 -c 'import secrets; print(secrets.token_urlsafe(16))'

   # OCIS JWT secret for collaboration service
   openssl rand -hex 32

   # Restic backup repository password
   openssl rand -base64 32

   # OAuth2 proxy cookie secret
   openssl rand -base64 32
   ```

Verification:

- Running `ls -la /mnt/mainpool/apps/data` shows the stack directories owned by `docker-apps`.
- Running `docker network ls` shows `traefik_net`, `backend_net`, and `ci_net` in the list.

### Phase 1: Portainer and GitHub Integration

Objective: To securely connect Portainer to your private GitHub repository.

Procedure:

1. Generate a GitHub Personal Access Token (PAT):

   - In GitHub, go to Settings → Developer settings → Personal access tokens → Tokens (classic).
   - Click Generate new token. Give it a descriptive name (e.g., `portainer-truenas-deploy`) and select the `repo` scope.
   - Click Generate token and copy the token immediately.

2. Add Git Credentials to Portainer:
   - In Portainer, navigate to Settings → Git Credentials.
   - Click Add credential.
   - Name: `github-deploy-token`.
   - Username: Your GitHub username.
   - Personal Access Token / Password: Paste the GitHub PAT.
   - Click Create credential.

### Phase 2: Gateway and Identity Deployment

Objective: To deploy the core entry point (Traefik) and the central authentication service (Keycloak).

General Deployment Procedure (for all stacks):

1. In Portainer, navigate to Stacks and click Add stack.
2. Give the stack its name (e.g., `proxy`).
3. Select Git Repository as the build method.
4. Repository URL: Enter the HTTPS URL of your private GitHub repository.
5. Compose path: Enter the path to the compose file _within the repository_ (e.g., `proxy/docker-compose.yml`).
6. Authentication: Enable this and select the `github-deploy-token`.
7. Environment variables: Copy the entire contents of both `/global.env` and the stack-specific `.env` file and paste them into the text box.
8. Click Deploy the stack.

Deployment Order:

1. Deploy the `proxy` stack.
2. Deploy the `iam` stack.

After deploying, all TLS-terminated services automatically receive security headers (HSTS, XSS protection, nosniff, frame-deny, CSP, referrer-policy) via the `security-headers` Traefik middleware defined in the proxy stack.

Verification:

- Both stacks deploy without errors. Check the logs for `proxy-traefik` and `iam-keycloak`.
- Navigate to `https://auth.yourdomain.com`. You should see the Keycloak landing page.
- Verify security headers: `curl -sI https://auth.yourdomain.com | grep -i 'strict-transport-security\|x-frame-options\|x-content-type-options\|x-xss-protection'`

### Phase 3: Keycloak Configuration (Post-Install)

Objective: To configure Keycloak with the necessary realms, clients, groups, and users, following the principle of least privilege.

Procedure:

1. Initial Login & Realm Creation:

   - Navigate to `https://auth.yourdomain.com` and click Administration Console.
   - Log in with the initial `admin` user from `/iam/.env`.
   - Create a new realm named `company-realm`.

2. Create User Groups:

   - In the `company-realm`, navigate to User Groups.
   - Create the following groups: `admins`, `developers`, `viewers`.

3. Create Clients for Services:

   - Navigate to Clients. For each client below, click Create client, set the Client ID, enable Client authentication, and save. Then, configure the settings as specified.
   - Client 1: `traefik-forward-auth`
     - Valid redirect URIs: `https://traefik.yourdomain.com/oauth2/callback`
     - Web origins: `https://traefik.yourdomain.com`
     - Action: Copy the Client secret into `/proxy/.env`.
   - Client 2: `forgejo`
     - Valid redirect URIs: `https://forgejo.yourdomain.com/user/oauth2/company-realm/callback`
     - Web origins: `https://forgejo.yourdomain.com`
     - Action: Copy the Client secret into `/operations/.env`.
   - Client 3: `grafana`
     - Valid redirect URIs: `https://grafana.yourdomain.com/login/generic_oauth`
     - Web origins: `https://grafana.yourdomain.com`
     - Action: Copy the Client secret into `/monitoring/.env`.
   - Client 4: `ocis`
     - Valid redirect URIs: `https://ocis.yourdomain.com/*`
     - Web origins: `https://ocis.yourdomain.com`
     - Action: Copy the Client secret into `/storage/.env`.

4. Configure Group Mappers:

   - For the `forgejo`, `grafana`, and `ocis` clients:
     - Go to the client's Client scopes tab, click the `-dedicated` scope.
     - Click Add mapper → By configuration → Group Membership.
     - Name: `groups`.
     - Token Claim Name: `groups`.
     - Ensure Add to ID token and Add to userinfo are ON.
     - Click Save.

5. Create Your Admin User and Delegate Privileges:

   - Navigate to Users and create a named user for yourself (e.g., `yourname`).
   - Go to the Credentials tab for your new user and set a password.
   - Go to the Role mappings tab. Click Assign role.
   - Filter by "clients" and assign the `realm-admin` role from the `realm-management` client.
   - Log out and log back in as your new user. Use this account for future management.

6. Commit Secrets and Redeploy:
   - On your local machine, update all the `.env` files with the secrets you copied.
   - Commit and push these changes to your GitHub repository.
   - In Portainer, navigate to the `proxy` stack, click Pull & redeploy, and toggle "Re-pull image and redeploy". This will apply the new secret.

> **Note:** Brute-force protection is enabled by default. 5 failed login attempts will temporarily lock the account. After 5 temporary lockouts, the account is permanently locked until an admin intervenes.

Verification:

- Test: Navigate to `https://traefik.yourdomain.com`. You should be redirected to Keycloak. Log in with the new user you created. You should be successfully logged in and see the Traefik dashboard.

### Phase 4: Core Services Deployment

Objective: To deploy the primary developer, communication, and storage tools.

Procedure:

1. Deploy `operations` Stack: Use the general deployment procedure. Compose path: `operations/docker-compose.yml`.
   - **Important:** The `ci_net` network must exist before deploying (created in Phase 0). Docker-in-Docker runs in this isolated network, not on the shared backend network.
   - Follow [this guide](https://www.domaindrivenarchitecture.org/posts/2025-05-19-sso-forgejo-with-keycoak/) to set up Keycloak and Forgejo authentication.
   - Create an OAuth2 Application in Forgejo for Woodpecker, copy the credentials into `/operations/.env`, commit/push, and redeploy the `operations` stack.

2. Deploy `collaboration` Stack:
   - One-Time Synapse Setup: SSH into your host and run `docker run --rm -v /mnt/mainpool/apps/data/collaboration/synapse:/data -e SYNAPSE_SERVER_NAME=yourdomain.com -e SYNAPSE_REPORT_STATS=no matrixdotorg/synapse:v1.103.0 generate`.
   - Use the general deployment procedure. Compose path: `collaboration/docker-compose.yml`.

3. Deploy `storage` Stack:
   - Set `OCIS_JWT_SECRET` to the value generated in Phase 0 (`openssl rand -hex 32`).
   - Use the general deployment procedure. Compose path: `storage/docker-compose.yml`.

> **Note:** The Forgejo web UI and container registry are now protected by Keycloak authentication (previously they were open). Woodpecker CI requires invite-only registration (`WOODPECKER_OPEN=false`).

Verification & Post-Install:

- Forgejo: Access `https://forgejo.yourdomain.com`, complete the setup, and configure the Keycloak OIDC authentication source in the admin settings.
- Matrix & OCIS: Verify that you can access and log in to both services via Keycloak.

### Phase 5: Monitoring, Utility, and Backups

Objective: To deploy the final supporting stacks.

Procedure:

1. Deploy the `monitoring` stack:
   - Set `LOKI_USERNAME` (default: `loki`) and `LOKI_PASSWORD` to the value generated in Phase 0.
   - The `loki-init` container will automatically generate a bcrypt hash and render the Loki config with authentication on first start.
   - Prometheus includes pre-configured alert rules and a Grafana dashboard for container resources.

2. Deploy the `utility` stack.

3. Deploy the `backup` stack:
   - Set `RESTIC_PASSWORD` to the value generated in Phase 0.
   - The backup cron triggers at 2:00 AM daily by default (configurable via `CRON_SCHEDULE` env var).
   - Backups use the retention policy: 24 hourly, 7 daily, 4 weekly, 6 monthly, 3 yearly.

Verification:

- Grafana: Access `https://grafana.yourdomain.com`, log in via Keycloak, and verify that the `Prometheus` and `Loki` data sources are connected.
- Prometheus: Access `https://prometheus.yourdomain.com`, go to Status → Targets, and verify all targets are "UP".
- Loki logs: Check that Promtail is successfully pushing logs by verifying the Loki datasource in Grafana shows recent log entries.
- Alerts: Check the "Container Resources" dashboard in Grafana and verify it loads with data.
- Backup: Run `docker exec backup-cron-trigger /usr/local/bin/run-cron` to trigger an immediate backup.

### Phase 6: Final System Hardening (TrueNAS UI)

Objective: To configure the final, multi-layered data protection strategy.

Procedure:

1. Configure ZFS Snapshots:
   - In the TrueNAS UI, navigate to Data Protection → Periodic Snapshot Tasks.
   - Create a daily, recursive snapshot of the `/mnt/mainpool/apps/data` dataset, scheduled to run _after_ your containerized backup job (e.g., at 4:00 AM).
   - Set a retention policy (e.g., keep for 2 weeks).

2. Database Backups:
   - The `scripts/db-backup.sh` script can be run manually or scheduled to dump all 5 PostgreSQL instances.
   - Default retention: 7 days of local SQL dumps.

Verification:

- Test Backups: Run `docker exec backup-cron-trigger /usr/local/bin/run-cron` and check the logs.
- Test Snapshots: Manually run the ZFS snapshot task and verify it appears on the Storage → Snapshots page.

---

## Security Reference

### Environment Variables (all stacks)

| Variable | Stack | Description |
|----------|-------|-------------|
| `CF_API_TOKEN` | proxy | Cloudflare API token for DNS challenge |
| `OAUTH2_PROXY_COOKIE_SECRET` | proxy | Cookie encryption secret (generate with `openssl rand -base64 32`) |
| `OAUTH2_PROXY_CLIENT_SECRET` | proxy | Keycloak client secret for forward auth |
| `KEYCLOAK_ADMIN_PASSWORD` | iam | Keycloak admin password |
| `KEYCLOAK_DATABASE_PASSWORD` | iam | Keycloak PostgreSQL password |
| `LOKI_PASSWORD` | monitoring | Loki authentication password (for Promtail + Grafana) |
| `GRAFANA_ADMIN_PASSWORD` | monitoring | Grafana local admin password |
| `GRAFANA_OIDC_CLIENT_SECRET` | monitoring | Grafana Keycloak client secret |
| `POSTGRES_PASSWORD_FORGEJO` | operations | Forgejo database password |
| `FORGEJO_OIDC_CLIENT_SECRET` | operations | Forgejo Keycloak OIDC client secret |
| `WOODPECKER_AGENT_SECRET` | operations | Woodpecker gRPC agent secret |
| `POSTGRES_PASSWORD_SYNAPSE` | collaboration | Synapse database password |
| `OCIS_JWT_SECRET` | storage | JWT secret for OCIS collaboration service |
| `OCIS_OIDC_CLIENT_SECRET` | storage | OCIS Keycloak client secret |
| `POSTGRES_PASSWORD_AKAUNTING` | accounting | Akaunting database password |
| `RESTIC_PASSWORD` | backup | Restic backup repository password |

### Docker Networks

| Network | Purpose | External Access |
|---------|---------|----------------|
| `traefik_net` | Public-facing services (Traefik labels) | Yes (via Traefik) |
| `backend_net` | Internal service-to-service communication | No (internal=true) |
| `ci_net` | Isolated CI workloads (Docker-in-Docker) | No |

### Known Exceptions

| Exception | Service | Reason |
|-----------|---------|--------|
| `privileged: true` | `docker-in-docker` (operations) | Required for Docker-in-Docker. Isolated on `ci_net`. |
| `cap_add: MKNOD` | `collabora` (storage) | Required by LibreOffice/Collabora for device node creation. |
| `read_only: false` | Most services | Required for application runtime state (config, data, logs). |

This comprehensive guide provides the definitive, verifiable path to deploying and confirming the operational readiness of your entire production platform.


