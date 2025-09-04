# SimpleInfrastructureStack

Simple infrasturcture stack for personal usage.

## Implementation Procedure: SimpleInfrastructureStack Deployment

It is critical to follow the phases in the specified order, as there are dependencies between the service stacks.

### Phase 0: Prerequisites and Foundational Setup

This foundational phase prepares the host environment. Do not skip any steps.

1. Clone the Git Repository:
   SSH into your TrueNAS SCALE server or a management machine that has `git` installed. Clone the repository to a local directory. This will be your reference for all configurations.

```bash
git clone https://github.com/WyattAu/SimpleInfrastructureStack.git
cd SimpleInfrastructureStack
```

2. Configure TrueNAS ZFS Datasets:
   All persistent application data will be stored on dedicated ZFS datasets to enable snapshots and robust data management.

- In the TrueNAS UI, navigate to `Datasets`.
- Create a parent dataset for all Docker data (e.g., `yourpool/docker`).
- Inside this, create the primary `appdata` dataset: `yourpool/docker/sis/appdata`.
- Under `appdata`, create a dataset for each logical stack. The final paths must match what will be in your environment files:
  - `/mnt/yourpool/docker/sis/appdata/proxy`
  - `/mnt/yourpool/docker/sis/appdata/iam`
  - `/mnt/yourpool/docker/sis/appdata/monitoring`
  - `/mnt/yourpool/docker/sis/appdata/dev`
  - `/mnt/yourpool/docker/sis/appdata/collaboration`
  - `/mnt/yourpool/docker/sis/appdata/operations`
- Recommendation: For each dataset, set `Compression` to `lz4` and `Enable Atime` to `off`.

3. Create Docker Networks:
   Manually create the required external networks via the TrueNAS SCALE shell. This ensures all stacks can communicate correctly.

```bash
docker network create traefik-public
docker network create shared-internal-net
```

4. Prepare Environment Variable Files:
   The repository does not contain `.env` files with secrets. You must create them.

- For each stack directory (`proxy`, `iam`, etc.), create a corresponding `.env` file.
- Copy the contents from the `*.env.example` files in the repository into your new local `.env` files.
- Crucially, generate all required secrets and credentials. Use `openssl rand -hex 32` or a password manager to generate strong, unique values for every placeholder marked with `!!!`.
- Create a single, consolidated `master.env` file on your local machine by combining all the individual `.env` files. This master file will be used for copy-pasting into Portainer. Ensure there are no duplicate variable names with conflicting values.

### Phase 1: Deployment of the Access Layer (Proxy Stack)

This stack is the entrypoint for all other services and must be deployed first.

1. Log into your Portainer instance.
2. Navigate to `Stacks` > `Add stack`.
3. Name: `proxy`
4. Build method: `Git Repository`
5. Repository URL: `https://github.com/WyattAu/SimpleInfrastructureStack.git`
6. Repository reference: `refs/heads/main`
7. Compose path: `proxy/docker-compose.yml`
8. Environment variables:
   - Click `Advanced options`.
   - Copy the entire contents of your local `proxy/.env` file and paste them into the `Environment variables` text box.
9. Click Deploy the stack.
10. Verification:
    - Check the logs for the `traefik` container. You should see it successfully parsing the command-line arguments, including your ACME email address. It should NOT show any errors about being unable to parse `${ACME_EMAIL}`.
    - Check the logs for the `cloudflare-ddns` container to confirm it is successfully updating your DNS records.
    - Navigate to the Traefik dashboard at `https://traefik.your-domain.com`. You will get a `404 page not found` error, but the browser must show a valid, secure SSL certificate (a padlock icon). This confirms that the ACME challenge via Cloudflare DNS was successful, which was the part that depended on the environment variable.

### Phase 2: Deployment of the Identity Layer (IAM Stack)

This stack provides authentication for all others. It is the most complex to set up due to its manual post-deployment steps.

1. In Portainer, navigate to `Stacks` > `Add stack`.
2. Name: `iam`
3. Build method: `Git Repository`
4. Repository URL & Reference: (Same as before)
5. Compose path: `iam/docker-compose.yml`
6. Environment variables: Copy and paste the contents of your `iam/.env` file.
7. Click Deploy the stack. Wait for all containers to be running and healthy.
8. CRITICAL - Post-Deployment Configuration:

   - Create Admin User: In Portainer, go to `Containers`, find `authentik-server`, and click the `>_` icon to open a console. Select `/bin/sh` and click `Connect`. Run the following command, replacing the password with the one from your `.env` file:

     ```sh
     ak create_user --username akadmin --password "${AUTHENTIK_BOOTSTRAP_PASSWORD}" --is-superuser
     ```

   - Log into Authentik: Navigate to `https://auth.your-domain.com` and log in as `akadmin`.
   - Create Traefik Provider:
     - In the Admin interface, go to `Applications` -> `Providers`.
     - Create a `Proxy Provider`. Name it `Traefik Provider`. Set Forward auth mode to `forward_auth (single application)`. Save.
   - Create Application:
     - Go to `Applications` -> `Applications`. Create an application.
     - Name it `Traefik Forward Auth`. Link it to the `Traefik Provider`. Save.
   - Create Outpost:
     - Go to `Outposts`. Create an `Embedded Outpost`.
     - Name it `Traefik Embedded Outpost`. Type: `proxy`. Integration: `Traefik`.
     - Select the `Traefik Forward Auth` application to be exposed. Save.
   - Retrieve Outpost Token:
     - Click `Edit` on the outpost you just created.
     - Under "Integration", you will see the `AUTHENTIK_TOKEN`. Copy this long token string.
   - Update the IAM Stack:
     - Go back to Portainer -> `Stacks` -> `iam`.
     - Click `Editor`. In the `Environment variables` section, add a new variable: `AUTHENTIK_OUTPOST_TOKEN` and paste the token you copied.
     - Click Update the stack. This will redeploy the `authentik-proxy` container with the correct token.

9. Verification: Navigate again to `https://traefik.your-domain.com`. You should now be redirected to the Authentik login page. A successful login should then show the `404 page not found` from Traefik. This confirms the forward auth integration is working.

### Phase 3: Deployment of the Observability Layer (Monitoring Stack)

Deploy this stack now to monitor the health of all subsequent deployments.

1. In Portainer, deploy a new stack named `monitoring` pointing to `monitoring/docker-compose.yml`.
2. Copy the contents of your `monitoring/.env` file into the environment variables section.
3. Deploy the stack.
4. Post-Deployment Configuration:
   - Navigate to `https://grafana.your-domain.com`. Log in with `admin` and the password you set in the `.env` file. Change the password when prompted.
   - Go to `Administration` -> `Data Sources`.
   - Add a Prometheus data source. The URL is `http://prometheus:9090`. Click `Save & Test`.
   - Add a Loki data source. The URL is `http://loki:3100`. Click `Save & Test`.
   - You can now import dashboards from the Grafana community to visualize Docker metrics and logs.
5. Verification: In Grafana's "Explore" tab, you should be able to query metrics from Prometheus and see logs from Loki (e.g., from the Traefik container).

### Phase 4: Deployment of the Core DevOps Loop (Dev Stack)

1. Deploy a new stack in Portainer named `dev` pointing to `dev/docker-compose.yml`.
2. Copy the contents of your `dev/.env` file into the environment variables.
3. Deploy the stack.
4. CRITICAL - Post-Deployment Gitea/Woodpecker Integration:
   - Navigate to `https://gitea.your-domain.com`. Complete the initial setup page, ensuring the database settings match your `.env` file. Create an admin user.
   - Log in as the Gitea admin. Go to `Settings` -> `Applications`.
   - Click `Manage OAuth2 Applications` > `Add Application`.
   - Application Name: `Woodpecker CI`
   - Redirect URIs: `https://ci.your-domain.com/authorize` (or whatever your Woodpecker subdomain is).
   - Save the application. Copy the generated Client ID and Client Secret.
   - Update the Dev Stack: Go back to Portainer -> `Stacks` -> `dev`. Click `Editor`.
   - Find the `WOODPECKER_GITEA_CLIENT_ID` and `WOODPECKER_GITEA_CLIENT_SECRET` variables and paste the values you just copied.
   - Click Update the stack.
5. Verification: Navigate to `https://ci.your-domain.com`. You should be redirected to Authentik for login. After logging in, you should see a "Login with Gitea" button. Clicking this should authorize Woodpecker and log you in successfully.

### Phase 5: Deployment of Collaboration & Operations Stacks

1. Collaboration Stack (Matrix):

- Deploy a new stack named `collaboration` pointing to `collaboration/docker-compose.yml`.
- Copy the contents of your `collaboration/.env` file.
- CRITICAL - Manual `homeserver.yaml` Configuration:
  1. Deploy the stack. The `synapse` container will start and then exit. This is expected.
  2. On your TrueNAS server, navigate to the volume path: `/mnt/yourpool/docker/sis/appdata/collaboration/synapse_data`. You will find a generated `homeserver.yaml`.
  3. Edit this file extensively. You must configure the `database` section to point to the PostgreSQL container, set up the `registration_shared_secret`, and review all other settings.
  4. Go back to Portainer -> `Stacks` -> `collaboration` and click Update the stack (with the "re-pull image" option disabled). The Synapse container should now start and stay running.

2. Operations Stack (Homepage & Taiga):

- Deploy a new stack named `operations` pointing to `operations/docker-compose.yml`.
- Copy the contents of your `operations/.env` file.
- Deploy the stack.
- CRITICAL - Post-Deployment Taiga/Authentik Integration:
  1. In the Authentik UI, create a new `OpenID Connect Provider` for Taiga.
  2. Set the Redirect URIs/Origins to `https://taiga.your-domain.com/*`.
  3. Assign it to an application and save. Copy the Client ID and Client Secret.
  4. Go back to Portainer -> `Stacks` -> `operations`. Click `Editor`.
  5. Update the `TAIGA_OIDC_CLIENT_ID` and `TAIGA_OIDC_CLIENT_SECRET` environment variables.
  6. Click Update the stack.

### Phase 6: Final System Verification

1. Navigate to `https://dashboard.your-domain.com`. You should be prompted to log in via Authentik. Once logged in, Homepage should display all your running services.
2. Test the OIDC login for Gitea, Grafana, and Taiga.
3. Test the full CI/CD loop: Push a commit to a test repository in Gitea and verify that a Woodpecker pipeline is automatically triggered.
4. Verify that you can register a user on your Matrix server and send messages.
5. In TrueNAS, navigate to `Datasets` and configure a periodic snapshot task for the parent `yourpool/docker/sis/appdata` dataset to ensure you have regular, consistent backups of all application data.

## Project structure

```sh
SimpleInfrastructureStack
├─ .yamllint.yml
├─ collaboration
│  └─ docker-compose.yml
├─ dev
│  └─ docker-compose.yml
├─ iam
│  └─ docker-compose.yml
├─ LICENSE
├─ monitoring
│  ├─ config
│  │  ├─ loki-config.yml
│  │  ├─ prometheus.yml
│  │  └─ promtail-config.yml
│  └─ docker-compose.yml
├─ operations
│  └─ docker-compose.yml
├─ proxy
│  ├─ config
│  │  ├─ dynamic.yml
│  │  └─ traefik.yml
│  └─ docker-compose.yml
└─ README.md

```
