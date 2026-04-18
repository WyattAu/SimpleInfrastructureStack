# ===================================================================
# SimpleInfrastructureStack - Terraform Infrastructure as Code
# ===================================================================
# Manages external infrastructure: Cloudflare DNS, Keycloak realm,
# and Forgejo organizations/users. Docker Compose + Ansible manage
# containers at runtime — Terraform does NOT manage Docker resources.
#
# Phases:
#   A - Cloudflare (DNS records, tunnel ingress)
#   B - Keycloak  (realm, clients, users, SMTP)
#   C - Forgejo   (organizations, teams, membership)
#
# Usage:
#   export TF_VAR_cf_api_token="..."     # from SOPS secrets/proxy.env.encrypted
#   export TF_VAR_kc_admin_password="..." # from SOPS secrets/iam.env.encrypted
#   export TF_VAR_forgejo_token="..."     # from Forgejo admin token
#   terraform init
#   terraform plan
#   terraform apply
#
# Secrets: TF_VAR values are set via environment variables, never stored
# in .tfstate (state only contains resource IDs and non-sensitive config).
# ===================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "4.52.7"
    }
    keycloak = {
      source  = "keycloak/keycloak"
      version = "4.5.0"
    }
    gitea = {
      source  = "go-gitea/gitea"
      version = "0.7.0"
    }
  }
}
