# Proxmox VE API provider.
#
# The API token is a TF_VAR sourced from SOPS (secrets/hosting.env) —
# never hardcode it here and never let it reach the state file.
#
# If the PVE host uses a self-signed certificate (default on a fresh
# install), keep pve_insecure = true and terminate nothing sensitive on
# this connection beyond the token itself; the API is reached over the
# management LAN only.

provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = var.pve_api_token
  insecure  = var.pve_insecure

  ssh {
    agent    = true
    username = var.pve_ssh_user
  }
}
