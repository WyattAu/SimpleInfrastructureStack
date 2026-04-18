# ===================================================================
# Phase A: Cloudflare Provider
# ===================================================================

provider "cloudflare" {
  api_token = var.cf_api_token
}

# Reference the existing zone (read-only data source)
data "cloudflare_zone" "main" {
  zone_id = var.cf_zone_id
}

# ===================================================================
# DNS Records — Active Services (point to TrueNAS: 62.49.93.199)
# ===================================================================

locals {
  # Services currently running on this TrueNAS
  active_services = {
    akaunting          = "Akaunting (accounting)"
    auth               = "Keycloak (SSO)"
    collabora          = "Collabora Online (document editing)"
    docs               = "Documentation (wiki/knowledge base)"
    element            = "Element Web (Matrix client)"
    forgejo            = "Forgejo (git hosting)"
    grafana            = "Grafana (dashboards)"
    homepage           = "Homepage (personal dashboard)"
    hookshot           = "Hookshot (GitHub bridge API)"
    kuma               = "Uptime Kuma (monitoring)"
    matrix             = "Synapse (Matrix federation)"
    oauth              = "OAuth2-Proxy (SSO middleware)"
    ocis               = "oCIS (file storage)"
    photos             = "Immich (photo management)"
    prometheus         = "Prometheus (metrics)"
    registry-forgejo   = "Forgejo container registry"
    rss                = "FreshRSS (feed reader)"
    traefik            = "Traefik (reverse proxy dashboard)"
    vault              = "Vaultwarden (password manager)"
    vpn                = "WireGuard VPN (DNS-only, no proxy)"
  }
}

# A + AAAA records for each active service
resource "cloudflare_record" "service_v4" {
  for_each = local.active_services

  zone_id = var.cf_zone_id
  name    = each.key
  type    = "A"
  content = var.primary_ipv4
  proxied = each.key != "vpn"  # VPN must be DNS-only for WireGuard
  ttl     = 1
}

resource "cloudflare_record" "service_v6" {
  for_each = local.active_services

  zone_id = var.cf_zone_id
  name    = each.key
  type    = "AAAA"
  content = var.primary_ipv6
  proxied = each.key != "vpn"
  ttl     = 1
}

# ===================================================================
# DNS Records — Tunnel Services (CNAME to tunnel)
# ===================================================================

# SSH and deploy go through the Cloudflare Tunnel
resource "cloudflare_record" "ssh" {
  zone_id = var.cf_zone_id
  name    = "ssh"
  type    = "CNAME"
  content = "${var.cf_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

resource "cloudflare_record" "deploy" {
  zone_id = var.cf_zone_id
  name    = "deploy"
  type    = "CNAME"
  content = "${var.cf_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# ===================================================================
# DNS Records — Static / Third-Party
# ===================================================================

# Email routing (managed by Cloudflare Email Routing — NOT in Terraform)
# MX records (route1/2/3.mx.cloudflare.net), DKIM, and DMARC are
# auto-managed by Cloudflare Email Routing and cannot be modified via API.
# These are documented here for reference but NOT imported into state.
# - MX: route1.mx.cloudflare.net (p=10), route2 (p=20), route3 (p=30)
# - DKIM: cf2024-1._domainkey TXT
# - DMARC: _dmarc TXT (v=DMARC1; p=none; ...)

# SPF record
resource "cloudflare_record" "spf" {
  zone_id  = var.cf_zone_id
  name     = "wyattau.com"
  type     = "TXT"
  content = "v=spf1 include:_spf.mx.cloudflare.net ~all"
  proxied  = false
  ttl      = 1
}

# Google site verification
resource "cloudflare_record" "google_site_verification" {
  zone_id  = var.cf_zone_id
  name     = "wyattau.com"
  type     = "TXT"
  content = "google-site-verification=3YGmsHSnCAxQTAZuYgJtLM-DGTAv9nj8vStESWghuXM"
  proxied  = false
  ttl      = 3600
}

# ===================================================================
# DNS Records — Stale (should be reviewed / deleted)
# ===================================================================
# These records point to old IPs and may be from previous deployments.
# They are imported here for visibility but could be removed.
# TODO: Review and clean up stale records

locals {
  # Records NOT managed by Terraform (stale or third-party)
  # These exist in Cloudflare but we're not importing them to avoid
  # accidental deletion. List them here for documentation:
  stale_records = {
    "ci.wyattau.com"              = "83.105.131.119 (old CI server)"
    "ci-grpc.wyattau.com"         = "83.105.131.119 (old CI server)"
    "dashboard.wyattau.com"       = "62.56.62.198 (old status page)"
    "gitea.wyattau.com"           = "90.249.121.197 (pre-Forgejo)"
    "owncloud.wyattau.com"        = "83.105.153.175 (pre-oCIS)"
    "oauth_old.wyattau.com"       = "83.105.153.175 (old OAuth server)"
    "registry.wyattau.com"        = "90.249.121.197 (old registry)"
    "seafile.wyattau.com"         = "62.49.213.217 (old Seafile)"
    "status.wyattau.com"          = "62.56.62.198 (old status page)"
    "taiga.wyattau.com"           = "83.104.43.127 (old Taiga)"
    "test.wyattau.com"            = "83.104.43.127 (test server)"
    "*.wyattau.com (wildcard)"    = "83.104.112.249 (catch-all)"
    "academics.wyattau.com"       = "wyattsnotes-academics.pages.dev (Cloudflare Pages)"
    "alevel.wyattau.com"          = "wyattsnotes-alevel.pages.dev (Cloudflare Pages)"
    "link.wyattau.com"            = "track.smtp2go.net (SMTP2Go click tracking)"
    "omniflutter-*.wyattau.com"   = "wyattau.github.io (GitHub Pages)"
    "programming.wyattau.com"     = "wyattsnotes-programming.pages.dev"
    "www.wyattau.com"             = "ssr-temp.pages.dev (temporary)"
    "wyattau.com (apex)"          = "ssr-temp.pages.dev (temporary)"
    "wyattsnotes.wyattau.com"     = "wyattsnotes.pages.dev (Cloudflare Pages)"
  }
}
