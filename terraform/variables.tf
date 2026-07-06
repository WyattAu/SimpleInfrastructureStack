# ===================================================================
# Terraform Variables
# ===================================================================
# Sensitive values are set via environment variables (TF_VAR_*)
# or via a .tfvars file (gitignored). Never hardcode secrets here.
# ===================================================================

# --- Cloudflare ---

variable "cf_api_token" {
  description = "Cloudflare API token (from SOPS secrets/proxy.env.encrypted)"
  type        = string
  sensitive   = true
}

variable "cf_zone_id" {
  description = "Cloudflare zone ID for wyattau.com (set via TF_VAR_cf_zone_id)"
  type        = string
}

variable "cf_account_id" {
  description = "Cloudflare account ID (set via TF_VAR_cf_account_id)"
  type        = string
}

variable "cf_tunnel_id" {
  description = "Cloudflare Tunnel ID (infra-tunnel)"
  type        = string
  default     = "75ad59d3-5247-43f4-982a-48fe88c62247"
}

# --- Keycloak Service Account ---
# Terraform authenticates as terraform-cli (dedicated service account).
# See terraform/keycloak.tf header for setup instructions.
# The legacy admin password variable was removed in favor of the SA.
variable "kc_sa_client_id" {
  description = "Keycloak service account client ID for Terraform (set TF_VAR_kc_sa_client_id)"
  type        = string
  default     = "terraform-cli"
}

variable "kc_sa_client_secret" {
  description = "Keycloak service account client secret (set TF_VAR_kc_sa_client_secret)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "kc_realm" {
  description = "Keycloak realm name"
  type        = string
  default     = "company-realm"
}

variable "kc_smtp_host" {
  description = "SMTP server hostname"
  type        = string
  default     = "mail.smtp2go.com"
}

variable "kc_smtp_port" {
  description = "SMTP server port"
  type        = number
  default     = 2525
}

variable "kc_smtp_user" {
  description = "SMTP authentication username"
  type        = string
  default     = "noreply@wyattau.com"
}

variable "kc_smtp_password" {
  description = "SMTP authentication password (from SOPS secrets/iam.env.encrypted)"
  type        = string
  sensitive   = true
}

variable "kc_smtp_from" {
  description = "SMTP From address"
  type        = string
  default     = "noreply@wyattau.com"
}

variable "kc_oauth2_proxy_secret" {
  description = "Keycloak client secret for oauth2-proxy (from SOPS secrets/proxy.env.encrypted)"
  type        = string
  sensitive   = true
}

variable "kc_grafana_secret" {
  description = "Keycloak client secret for Grafana (from SOPS secrets/monitoring.env.encrypted)"
  type        = string
  sensitive   = true
}

variable "kc_forgejo_secret" {
  description = "Keycloak client secret for Forgejo (from SOPS secrets/iam.env.encrypted: FORGEJO_KEYCLOAK_CLIENT_SECRET)"
  type        = string
  sensitive   = true
}

# --- Forgejo ---

variable "forgejo_base_url" {
  description = "Forgejo base URL"
  type        = string
  default     = "https://forgejo.wyattau.com"
}

variable "forgejo_token" {
  description = "Forgejo admin API token"
  type        = string
  sensitive   = true
}

# --- Infra ---

variable "primary_ipv4" {
  description = "TrueNAS primary IPv4 address"
  type        = string
  default     = "62.49.93.199"
}

variable "primary_ipv6" {
  description = "TrueNAS primary IPv6 address"
  type        = string
  default     = "2a0a:ef40:1175:d801:6e4b:90ff:fe48:c063"
}
