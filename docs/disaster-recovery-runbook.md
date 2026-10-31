No local backups or configuration files are required; everything is reproducible from source.
1. **Age encryption key**; Used by SOPS to encrypt/decrypt secrets
2. **GitHub credentials**; Access to the repository
3. **Backblaze B2 credentials**; Access to offsite backups
4. **Cloudflare API token**; Used by Terraform for DNS management
5. **Forgejo admin token**; Used by Terraform for org/team management