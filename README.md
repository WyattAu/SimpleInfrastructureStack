# SimpleInfrastructureStack

Simple infrasturcture stack for personal usage.

## Implementation Procedure

Prerequisites:

- All files from the final, definitive set are committed and pushed to a private GitHub repository.
- You have shell (SSH) access to the TrueNAS SCALE host.
- You have administrator access to the Portainer UI.

## Phase 0: Host and System Preparation (One-Time Setup)

Objective: To prepare the TrueNAS host with the foundational users, directories, and networks required by all subsequent stacks.

Procedure:

1.  Create ZFS Datasets:

    - In the TrueNAS UI, navigate to Datasets.
    - Create the parent dataset for all application configurations and data: `/mnt/mainpool/apps`.
    - Under `/mnt/mainpool/apps`, create the primary data volume dataset: `data`.
    - Under `/mnt/mainpool/apps`, create the primary backup dataset: `backups`.
    - Under `/mnt/mainpool/apps/data`, create the following child datasets: `proxy`, `iam`, `operations`, `collaboration`, `monitoring`, `storage`, `utility`.

2.  Create Dedicated User:

    - In the TrueNAS UI, navigate to Credentials -> Local Users.
    - Create a new user named `docker-apps`.
    - Set the User ID (UID) and Primary Group ID (GID) to `1001`.
    - Disable password login for this user.

3.  Set Data Permissions:

    - Navigate back to the `/mnt/mainpool/apps` dataset.
    - Edit its permissions, select the `docker-apps` user, and grant it `Read`, `Write`, and `Execute` access.
    - Ensure the permission changes are applied recursively to all child datasets.

4.  Create Shared Docker Networks:
    - SSH into your TrueNAS host.
    - Execute the following commands:
      ```bash
      docker network create traefik_net
      docker network create backend_net
      ```

Verification:

- Running `ls -la /mnt/mainpool/apps/data` shows the stack directories owned by `docker-apps`.
- Running `docker network ls` shows `traefik_net` and `backend_net` in the list.

## Phase 1: Portainer and GitHub Integration

Objective: To securely connect Portainer to your private GitHub repository.

Procedure:

1.  Generate a GitHub Personal Access Token (PAT):

    - In GitHub, go to Settings -> Developer settings -> Personal access tokens -> Tokens (classic).
    - Click Generate new token. Give it a descriptive name (e.g., `portainer-truenas-deploy`) and select the `repo` scope.
    - Click Generate token and copy the token immediately.

2.  Add Git Credentials to Portainer:
    - In Portainer, navigate to Settings -> Git Credentials.
    - Click Add credential.
    - Name: `github-deploy-token`.
    - Username: Your GitHub username.
    - Personal Access Token / Password: Paste the GitHub PAT.
    - Click Create credential.

## Phase 2: Gateway and Identity Deployment

Objective: To deploy the core entry point (Traefik) and the central authentication service (Keycloak).

General Deployment Procedure (for all stacks):

1.  In Portainer, navigate to Stacks and click Add stack.
2.  Give the stack its name (e.g., `proxy`).
3.  Select Git Repository as the build method.
4.  Repository URL: Enter the HTTPS URL of your private GitHub repository.
5.  Compose path: Enter the path to the compose file _within the repository_ (e.g., `proxy/docker-compose.yml`).
6.  Authentication: Enable this and select the `github-deploy-token`.
7.  Environment variables: Copy the entire contents of both `/global.env` and the stack-specific `.env` file and paste them into the text box.
8.  Click Deploy the stack.

Deployment Order:

1.  Deploy the `proxy` stack.
2.  Deploy the `iam` stack.

Verification:

- Both stacks deploy without errors. Check the logs for `proxy-traefik` and `iam-keycloak`.
- Navigate to `https://auth.yourdomain.com`. You should see the Keycloak landing page.

## Phase 3: Keycloak Configuration (Post-Install)

Objective: To configure Keycloak with the necessary realms, clients, groups, and users, following the principle of least privilege.

Procedure:

1.  Initial Login & Realm Creation:

    - Navigate to `https://auth.yourdomain.com` and click Administration Console.
    - Log in with the initial `admin` user from `/iam/.env`.
    - Create a new realm named `company-realm`.

2.  Create User Groups:

    - In the `company-realm`, navigate to User Groups.
    - Create the following groups: `admins`, `developers`, `viewers`.

3.  Create Clients for Services:

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

4.  Configure Group Mappers:

    - For the `forgejo`, `grafana`, and `ocis` clients:
      - Go to the client's Client scopes tab, click the `-dedicated` scope.
      - Click Add mapper -> By configuration -> Group Membership.
      - Name: `groups`.
      - Token Claim Name: `groups`.
      - Ensure Add to ID token and Add to userinfo are ON.
      - Click Save.

5.  Create Your Admin User and Delegate Privileges:

    - Navigate to Users and create a named user for yourself (e.g., `yourname`).
    - Go to the Credentials tab for your new user and set a password.
    - Go to the Role mappings tab. Click Assign role.
    - Filter by "clients" and assign the `realm-admin` role from the `realm-management` client.
    - Log out and log back in as your new user. Use this account for future management.

6.  Commit Secrets and Redeploy:
    - On your local machine, update all the `.env` files with the secrets you copied.
    - Commit and push these changes to your GitHub repository.
    - In Portainer, navigate to the `proxy` stack, click Pull & redeploy, and toggle "Re-pull image and redeploy". This will apply the new secret.

Verification:

- Test: Navigate to `https://traefik.yourdomain.com`. You should be redirected to Keycloak. Log in with the new user you created. You should be successfully logged in and see the Traefik dashboard.

## Phase 4: Core Services Deployment

Objective: To deploy the primary developer, communication, and storage tools.

Procedure:

1.  Deploy `operations` Stack: Use the general deployment procedure. Compose path: `operations/docker-compose.yml`.
2.  Follow this guide <https://www.domaindrivenarchitecture.org/posts/2025-05-19-sso-forgejo-with-keycoak/> to setup keyclaok and forgejo authentication.
3.  Deploy `collaboration` Stack:
    - One-Time Synapse Setup: SSH into your host and run `docker run --rm -v /mnt/mainpool/apps/data/collaboration/synapse:/data -e SYNAPSE_SERVER_NAME=yourdomain.com -e SYNAPSE_REPORT_STATS=no matrixdotorg/synapse:v1.103.0 generate`.
    - Use the general deployment procedure. Compose path: `collaboration/docker-compose.yml`.
4.  Deploy `storage` Stack: Use the general deployment procedure. Compose path: `storage/docker-compose.yml`.

Verification & Post-Install:

- Forgejo: Access `https://forgejo.yourdomain.com`, complete the setup, and configure the Keycloak OIDC authentication source in the admin settings. Then, create an OAuth2 Application for Woodpecker, copy the credentials into `/operations/.env`, commit/push, and redeploy the `operations` stack.
- Matrix & OCIS: Verify that you can access and log in to both services via Keycloak.

## Phase 5: Visibility, Utility, and Backups

Objective: To deploy the final supporting stacks.

Procedure:

1.  Deploy the `monitoring` stack.
2.  Deploy the `utility` stack.
3.  Deploy the `backup` stack.

Verification:

- Grafana: Access `https://grafana.yourdomain.com`, log in via Keycloak, and verify that the `Prometheus` and `Loki` data sources are connected.
- Prometheus: Access `https://prometheus.yourdomain.com`, go to Status -> Targets, and verify all targets are "UP".
- Backup: The `backup-restic` container will run its `init` command and then wait. The `backup-cron-trigger` will show it has registered the job.

## Phase 6: Final System Hardening (TrueNAS UI)

Objective: To configure the final, multi-layered data protection strategy.

Procedure:

1.  Configure ZFS Snapshots:
    - In the TrueNAS UI, navigate to Data Protection -> Periodic Snapshot Tasks.
    - Create a daily, recursive snapshot of the `/mnt/mainpool/apps/data` dataset, scheduled to run _after_ your containerized backup job (e.g., at 4:00 AM).
    - Set a retention policy (e.g., keep for 2 weeks).

Verification:

- Test Backups: To test the containerized backup immediately, SSH into the host and run `docker exec backup-cron-trigger /usr/local/bin/run-cron`.
- Success: Check the logs of the `backup-restic` container to see the backup process. Check the `/mnt/mainpool/apps/backups/restic-repo` directory to confirm data has been written.
- Test Snapshots: Manually run the ZFS snapshot task and verify it appears on the Storage -> Snapshots page.

This comprehensive guide provides the definitive, verifiable path to deploying and confirming the operational readiness of your entire production platform.
