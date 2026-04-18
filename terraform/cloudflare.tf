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
# WAF — Geo-Blocking Rules
# ===================================================================
# Blocks requests from high-risk countries to reduce scanner noise.
# Uses Cloudflare WAF custom rules (zone-level ruleset).
#
# Exceptions:
#   - Matrix federation endpoints (/.well-known/matrix/*) must be globally accessible
#   - ACME challenge requests (*.acme-challenge.*) must pass for TLS certificate renewal
#   - Hookshot (GitHub bridge API) must accept webhooks from GitHub globally

variable "geo_blocked_countries" {
  description = "ISO 3166-1 alpha-2 country codes to block"
  type        = list(string)
  default     = ["CN", "RU", "KP", "IR", "SY"]
}

locals {
  # Build country match expression: "CN" "RU" "KP" → {"CN" "RU" "KP"}
  geo_blocked_expr = join(" ", [for c in var.geo_blocked_countries : "\"${c}\""])
}

resource "cloudflare_ruleset" "geo_block" {
  account_id  = var.cf_account_id
  zone_id     = var.cf_zone_id
  name        = "Geo-blocking: high-risk countries"
  description = "Block HTTP requests from high-risk countries with exceptions for federation and ACME"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  # Expression logic:
  #   Block if country matches AND NOT (Matrix federation OR ACME challenge OR Hookshot)
  rules {
    action     = "block"
    expression = <<-EXPR
      (ip.geoip.country in {${local.geo_blocked_expr}})
      and not (
        http.request.uri.path contains "/.well-known/matrix"
        or http.request.uri.path contains "/.well-known/openid-configuration"
        or http.host contains "hookshot"
        or http.request.uri.path contains ".well-known/acme-challenge"
      )
    EXPR
    description = "Block high-risk countries (exceptions: Matrix federation, OIDC discovery, ACME, Hookshot)"
    enabled     = true
  }
}

# Email routing (managed by Cloudflare Email Routing — NOT in Terraform)
# MX records and DKIM are auto-managed by Cloudflare Email Routing and
# cannot be modified via API. Documented here for reference only.
# - MX: route1.mx.cloudflare.net (p=10), route2 (p=20), route3 (p=30)
# - DKIM: cf2024-1._domainkey TXT

# DMARC record (can be managed via API — not controlled by Email Routing)
resource "cloudflare_record" "dmarc" {
  zone_id  = var.cf_zone_id
  name     = "_dmarc"
  type     = "TXT"
  content = "v=DMARC1; p=none; rua=mailto:1aa26a2e9a5c459fb892d8df10af4f3b@dmarc-reports.cloudflare.net"
  proxied  = false
  ttl      = 1
}

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
# DNS Records — Third-Party (not managed by Terraform)
# ===================================================================
# These records are managed by external services or are intentional.

locals {
  third_party_records = {
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
