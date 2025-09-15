# SimpleInfrastructureStack

Simple infrasturcture stack for personal usage.

## Implementation Procedure

### Phase 0: Host and System Preparation (One-Time Setup)

Objective: To prepare the TrueNAS host with the foundational users, directories, and networks required by all subsequent stacks.

Procedure:

1.  Create ZFS Datasets:

    - In the TrueNAS UI, navigate to Datasets.
    - Create the parent dataset: `/mnt/mainpool/sis`.
    - Under `sis`, create the `appdata` and `backups` child datasets.
    - Under `sis/appdata`, create the child datasets for each stack: `proxy`, `iam`, `operations`, `collaboration`, `monitoring`, `storage`, `utility`.

2.  Create Dedicated User:

    - In the TrueNAS UI, create a local user `dapps` with UID/GID `1001`.
    - Disable password login.

3.  Set Data Permissions:

    - Edit the permissions on the `/mnt/mainpool/sis` dataset, granting `dapps` full control, and apply them recursively.

4.  Create Shared Docker Networks:

    - SSH into your TrueNAS host.
    - Execute:

      ```bash
      docker network create traefik_net
      docker network create backend_net
      ```

Verification:

- `ls -la /mnt/mainpool/sis/appdata` shows directories owned by `dapps`.
- `docker network ls` shows `traefik_net` and `backend_net`.

### Phase 1: Portainer and GitHub Integration

Objective: To securely connect Portainer to your private GitHub repository.

Procedure:

1.  Generate a GitHub Personal Access Token (PAT):

    - In GitHub, go to Settings -> Developer settings -> Personal access tokens -> Tokens (classic).
    - Click Generate new token.
    - Note: "Fine-grained tokens" are newer but may have compatibility issues with some tools. "Classic" tokens are a safe bet.
    - Give the token a descriptive name (e.g., `portainer-truenas-deploy`).
    - Set an expiration date.
    - Under Select scopes, check the `repo` scope. This grants full control of private repositories.
    - Click Generate token.
    - CRITICAL: Copy the token immediately. You will never see it again. Store it securely in a password manager.

2.  Add Git Credentials to Portainer:
    - In Portainer, navigate to Settings -> Git Credentials.
    - Click Add credential.
    - Name: `github-deploy-token`
    - Username: Your GitHub username.
    - Personal Access Token / Password: Paste the GitHub PAT you just generated.
    - Click Create credential.

### Phase 2: Stacks Deployment from GitHub

Objective: To deploy all service stacks sequentially using the new Git credentials.

General Deployment Procedure for Each Stack:

1.  In Portainer, navigate to Stacks and click Add stack.
2.  Give the stack its name (e.g., `proxy`).
3.  Select Git Repository as the build method.
4.  Repository URL: Enter the HTTPS URL of your forked private GitHub repository (This one being `https://github.com/WyattAu/SimpleInfrastructureStack.git`).
5.  Repository reference: Leave as `refs/heads/main` to use the main branch.
6.  Compose path: Enter the path to the compose file _within the repository_ (e.g., `proxy/docker-compose.yml`).
7.  Authentication: Enable this and select the `github-deploy-token` you created in Phase 1.
8.  Environment variables: Copy the entire contents of both `/global.env` and the stack-specific `.env` file (e.g., `/proxy/.env`) from your local machine and paste them into the text box.
9.  Click Deploy the stack.

Deployment Order:

1.  Deploy `proxy` Stack (Compose path: `proxy/docker-compose.yml`)
2.  Deploy `iam` Stack (Compose path: `iam/docker-compose.yml`)

Verification:

- Both stacks deploy without errors.
- Verify the full authentication loop by navigating to `https://traefik.yourcompany.com`. You should be redirected to `https://auth.yourcompany.com` for login.

### Phase 3: Post-Install Setup - Keycloak and Secrets Update

Objective: To configure Keycloak and then update your Git repository with the generated secrets.

Procedure:

1.  Configure Keycloak:

    - Follow the detailed steps from the previous guide to:
      - Log in to Keycloak with the initial admin user.
      - Create the `company-realm`.
      - Create the `admins`, `developers`, `viewers` groups.
      - Create clients for `traefik-forward-auth`, `gitea`, `grafana`, and `oauth2-proxy`.
      - For each client, copy its generated Client Secret.

2.  Update Local `.env` Files:

    - On your local development machine (not the server), paste the copied secrets into the corresponding `.env` files: `/proxy/.env`, `/operations/.env`, `/monitoring/.env`, and `/storage/.env`.

3.  Commit and Push Secrets:

    - Commit the changes to your local `.env` files.
    - Push the changes to your GitHub repository.

4.  Redeploy Stacks with New Secrets:

    - In Portainer, navigate to the `proxy` stack.
    - Click Pull & redeploy. Portainer will pull the latest commit from GitHub (which now includes the secret) and restart the services.
    - _(You will repeat this "Pull & redeploy" step for the other stacks after they are deployed.)_

5.  Create Your Admin User:
    - Follow the security best practice from the previous guide: create a named user for yourself in Keycloak and assign it the `realm-admin` role. Log out as the initial admin and log back in as yourself.

### Phase 4: Core Services Deployment

Objective: To deploy the remaining operational stacks.

Procedure:

1.  Deploy `operations` Stack:

    - Use the general deployment procedure. Compose path: `operations/docker-compose.yml`.

2.  Deploy `collaboration` Stack:

    - One-Time Synapse Setup: SSH into your host and run `docker run --rm -v /mnt/mainpool/sis/appdata/collaboration/synapse:/data -e SYNAPSE_SERVER_NAME=yourcompany.com -e SYNAPSE_REPORT_STATS=no matrixdotorg/synapse:v1.103.0 generate`.
    - Use the general deployment procedure. Compose path: `collaboration/docker-compose.yml`.

3.  Deploy `storage` Stack:
    - Use the general deployment procedure. Compose path: `storage/docker-compose.yml`.

Verification & Post-Install:

- Verify Gitea: Access `https://gitea.yourcompany.com`, complete the setup, and configure the Keycloak OIDC authentication source in the admin settings.
- Verify Matrix & OCIS: Verify that you can access and log in to both services via Keycloak.

### Phase 5: Visibility, Utility, and Backups

Objective: To deploy the final supporting stacks.

Procedure:

1.  Deploy `monitoring` Stack:

    - Use the general deployment procedure. Compose path: `monitoring/docker-compose.yml`.

2.  Deploy `utility` Stack:

    - Use the general deployment procedure. Compose path: `utility/docker-compose.yml`.

3.  Deploy `backup` Stack:
    - Use the general deployment procedure. Compose path: `backup/docker-compose.yml`.

Verification:

- Verify Grafana, Prometheus, and Homepage as previously described.
- The `backup-restic-cron` container will run its `init` command and stop, which is correct.

### Phase 6: Final System Hardening (TrueNAS UI)

Objective: To configure the final layer of data protection using native TrueNAS features.

Procedure:

1.  Configure the Backup Cron Job:

    - In the TrueNAS UI, navigate to System Settings -> Cron Jobs.
    - Click Add.
    - Description: `Restic Backup Job`.
    - User: `root`.
    - Schedule: Set your desired schedule (e.g., daily at 3:00 AM).
    - Command: Paste the long, single-line `docker run...` command from the previous guide.
    - Save the cron job.

2.  Configure ZFS Snapshots:
    - In the TrueNAS UI, navigate to Data Protection -> Periodic Snapshot Tasks.
    - Create a daily, recursive snapshot of the `/mnt/mainpool/sis/appdata` dataset, scheduled to run _after_ the Restic cron job (e.g., at 4:00 AM).

Verification:

- Manually run the cron job and verify that data appears in your `/mnt/mainpool/sis/backups/restic-repo` directory.
- Manually run the snapshot task and verify it appears on the Storage -> Snapshots page.

This GitHub-centric procedure provides a secure, auditable, and easily repeatable method for deploying and managing your entire production platform.
