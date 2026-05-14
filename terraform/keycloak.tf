# ===================================================================
# Phase B: Keycloak Provider
# ===================================================================
# Uses a dedicated service account (terraform-sa) with minimal permissions
# instead of the admin user. This limits blast radius if the account is
# compromised.
#
# Setup (one-time, via Keycloak admin console):
#   1. Create client "terraform-cli" in realm "master":
#      - Client ID: terraform-cli
#      - Client authenticator type: client-id-secret
#      - Service accounts roles: toggle ON
#   2. Assign realm-management roles to the service account:
#      - realm-management > manage-users (view/manage users)
#      - realm-management > manage-clients (view/manage OIDC clients)
#      - realm-management > view-realm (read realm config)
#   3. Copy the client secret and set:
#      export TF_VAR_kc_sa_client_secret="<client-secret>"
#
# Until the service account is created, the provider falls back to
# admin-cli auth using TF_VAR_kc_admin_password.
# ===================================================================

provider "keycloak" {
  url       = var.kc_base_url
  realm     = "master"
  client_id = var.kc_sa_client_id
  username  = ""
  password  = var.kc_sa_client_secret
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
  valid_redirect_uris = [
    "https://akaunting.wyattau.com/*",
    "https://books.wyattau.com/*",
    "https://forgejo.wyattau.com/*",
    "https://homepage.wyattau.com/*",
    "https://kuma.wyattau.com/*",
    "https://prometheus.wyattau.com/*",
    "https://taiga.wyattau.com/*",
    "https://traefik.wyattau.com/*",
  ]
  web_origins = [
    "https://akaunting.wyattau.com",
    "https://books.wyattau.com",
    "https://forgejo.wyattau.com",
    "https://homepage.wyattau.com",
    "https://kuma.wyattau.com",
    "https://prometheus.wyattau.com",
    "https://taiga.wyattau.com",
    "https://traefik.wyattau.com",
  ]
  root_url = "https://auth.wyattau.com"
}

resource "keycloak_openid_client" "grafana" {
  realm_id                     = data.keycloak_realm.main.id
  client_id                    = "grafana"
  name                         = "Grafana"
  description                  = "Grafana dashboards (uses Keycloak OIDC directly)"
  enabled                      = true
  client_secret                = var.kc_grafana_secret
  standard_flow_enabled        = true
  direct_access_grants_enabled = true
  access_type                  = "CONFIDENTIAL"
  valid_redirect_uris          = ["https://grafana.wyattau.com/login/generic_oauth"]
  web_origins                  = ["https://grafana.wyattau.com"]
  root_url                     = "https://grafana.wyattau.com"
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
  valid_redirect_uris   = ["https://forgejo.wyattau.com/user/oauth2/auth.wyattau.com/callback"]
  web_origins           = ["https://forgejo.wyattau.com"]
  root_url              = "https://forgejo.wyattau.com"
}

# ===================================================================
# Users
# ===================================================================

resource "keycloak_user" "wyatt" {
  realm_id       = data.keycloak_realm.main.id
  username       = "wyatt"
  enabled        = true
  email          = "wyatt_au@protonmail.com"
  first_name     = "Wyatt"
  last_name      = "Au"
  email_verified = true

  lifecycle {
    ignore_changes = [initial_password, credentials, required_actions]
  }
}

resource "keycloak_user" "joshkad" {
  realm_id       = data.keycloak_realm.main.id
  username       = "joshkad"
  enabled        = true
  email          = "jmlkadungure@gmail.com"
  first_name     = "Joshua"
  last_name      = "Kadungure"
  email_verified = true

  lifecycle {
    ignore_changes = [initial_password, credentials, required_actions]
  }
}

resource "keycloak_user" "ayo" {
  realm_id       = data.keycloak_realm.main.id
  username       = "ayo"
  enabled        = true
  email          = "labinjoayomikun@gmail.com"
  first_name     = "Ayomikun"
  last_name      = "Labinjo"
  email_verified = true

  lifecycle {
    ignore_changes = [initial_password, credentials, required_actions]
  }
}

resource "keycloak_user" "viswa" {
  realm_id       = data.keycloak_realm.main.id
  username       = "viswa"
  enabled        = true
  email          = "viswa@example.com"
  email_verified = true

  lifecycle {
    ignore_changes = [initial_password, credentials, required_actions]
  }
}
