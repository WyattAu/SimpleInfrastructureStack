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
  description = "Cloudflare zone ID for wyattau.com"
  type        = string
  default     = "55ec52794cd169def38cb5ca2cad3481"
}

variable "cf_account_id" {
  description = "Cloudflare account ID"
  type        = string
  default     = "26966ba2f4b3a12cb750cd615c8d0bcf"
}

variable "cf_tunnel_id" {
  description = "Cloudflare Tunnel ID (infra-tunnel)"
  type        = string
  default     = "75ad59d3-5247-43f4-982a-48fe88c62247"
}

# --- Keycloak ---

variable "kc_base_url" {
  description = "Keycloak base URL (public, via Cloudflare proxy)"
  type        = string
  default     = "https://auth.wyattau.com"
}

variable "kc_admin_username" {
  description = "Keycloak admin username"
  type        = string
  default     = "admin"
}

variable "kc_admin_password" {
  description = "Keycloak admin password (from SOPS secrets/iam.env.encrypted)"
  type        = string
  sensitive   = true
}

variable "kc_realm" {
  description = "Keycloak realm name"
  type        = string
  default     = "company-realm"
}

variable "kc_smtp_host" {
  description = "SMTP server hostname"
  type        = string
  default     = "smtp.protonmail.ch"
}

variable "kc_smtp_port" {
  description = "SMTP server port"
  type        = number
  default     = 587
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
