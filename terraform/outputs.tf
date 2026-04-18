# ===================================================================
# Terraform Outputs
# ===================================================================

output "cloudflare_zone" {
  value       = data.cloudflare_zone.main.name
  description = "Cloudflare zone name"
}

output "active_dns_records" {
  value       = { for k, v in cloudflare_record.service_v4 : k => v.name }
  description = "Active service DNS records managed by Terraform"
}

output "keycloak_realm" {
  value       = data.keycloak_realm.main.realm
  description = "Keycloak realm name"
}

output "keycloak_clients" {
  value       = [for c in [keycloak_openid_client.oauth2_proxy, keycloak_openid_client.grafana, keycloak_openid_client.forgejo] : c.client_id]
  description = "Keycloak OIDC clients managed by Terraform"
}

output "forgejo_orgs" {
  value       = [for o in [gitea_org.questhive, gitea_org.blocmarket, gitea_org.rankhub, gitea_org.aether, gitea_org.deontic, gitea_org.suture] : o.name]
  description = "Forgejo organizations managed by Terraform"
}

output "geo_blocked_countries" {
  value       = var.geo_blocked_countries
  description = "Country codes blocked by Cloudflare WAF geo-blocking rule"
}
