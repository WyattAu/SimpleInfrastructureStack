# ===================================================================
# Phase B: Keycloak Provider
# ===================================================================

provider "keycloak" {
  url             = var.kc_base_url
  realm           = "master"
  client_id       = "admin-cli"
  username        = var.kc_admin_username
  password        = var.kc_admin_password
}

# ===================================================================
# Realm
# ===================================================================

data "keycloak_realm" "main" {
  realm = var.kc_realm
}

# ===================================================================
# SMTP Configuration
# ===================================================================
# NOTE: keycloak provider v4 does not have a realm_smtp resource.
# SMTP is managed via Ansible (keycloak-smtp role) which calls the
# Keycloak admin REST API directly. The variables remain defined
# for documentation/reference purposes.

# ===================================================================
# OIDC Clients
# ===================================================================

resource "keycloak_openid_client" "oauth2_proxy" {
  realm_id              = data.keycloak_realm.main.id
  client_id             = "oauth2-proxy"
  name                  = "OAuth2 Proxy"
  description           = "Traefik forward-auth middleware for SSO"
  enabled               = true
  client_secret         = var.kc_oauth2_proxy_secret
  standard_flow_enabled = true
  access_type           = "CONFIDENTIAL"
  valid_redirect_uris   = [
    "https://akaunting.wyattau.com/*",
    "https://forgejo.wyattau.com/*",
    "https://homepage.wyattau.com/*",
    "https://kuma.wyattau.com/*",
    "https://prometheus.wyattau.com/*",
    "https://taiga.wyattau.com/*",
    "https://traefik.wyattau.com/*",
  ]
  web_origins           = [
    "https://akaunting.wyattau.com",
    "https://forgejo.wyattau.com",
    "https://homepage.wyattau.com",
    "https://kuma.wyattau.com",
    "https://prometheus.wyattau.com",
    "https://taiga.wyattau.com",
    "https://traefik.wyattau.com",
  ]
  root_url              = "https://auth.wyattau.com"
}

resource "keycloak_openid_client" "grafana" {
  realm_id              = data.keycloak_realm.main.id
  client_id             = "grafana"
  name                  = "Grafana"
  description           = "Grafana dashboards (uses Keycloak OIDC directly)"
  enabled               = true
  client_secret         = var.kc_grafana_secret
  standard_flow_enabled = true
  direct_access_grants_enabled = true
  access_type           = "CONFIDENTIAL"
  valid_redirect_uris   = ["https://grafana.wyattau.com/login/generic_oauth"]
  web_origins           = ["https://grafana.wyattau.com"]
  root_url              = "https://grafana.wyattau.com"
}

resource "keycloak_openid_client" "forgejo" {
  realm_id              = data.keycloak_realm.main.id
  client_id             = "forgejo"
  name                  = "Forgejo"
  description           = "Forgejo git hosting (SSO integration)"
  enabled               = true
  client_secret         = var.kc_forgejo_secret
  standard_flow_enabled = true
  access_type           = "CONFIDENTIAL"
  valid_redirect_uris   = ["https://forgejo.wyattau.com/user/login"]
  web_origins           = ["https://forgejo.wyattau.com"]
  root_url              = "https://forgejo.wyattau.com"
}

# ===================================================================
# Users
# ===================================================================

resource "keycloak_user" "wyatt" {
  realm_id   = data.keycloak_realm.main.id
  username   = "wyatt"
  enabled    = true
  email      = "wyatt_au@protonmail.com"
  first_name = "Wyatt"
  last_name  = "Au"
  email_verified = true
}

resource "keycloak_user" "joshkad" {
  realm_id        = data.keycloak_realm.main.id
  username        = "joshkad"
  enabled         = true
  email           = "jmlkadungure@gmail.com"
  first_name      = "Joshua"
  last_name       = "Kadungure"
  email_verified  = true
}

resource "keycloak_user" "ayo" {
  realm_id        = data.keycloak_realm.main.id
  username        = "ayo"
  enabled         = true
  email           = "labinjoayomikun@gmail.com"
  first_name      = "Ayomikun"
  last_name       = "Labinjo"
  email_verified  = true
}

resource "keycloak_user" "viswa" {
  realm_id        = data.keycloak_realm.main.id
  username        = "viswa"
  enabled         = true
  email_verified  = true

  lifecycle {
    ignore_changes = [required_actions]
  }
}
