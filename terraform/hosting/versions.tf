# ===================================================================
# Hosting platform — Proxmox VE (EPYC node at business premises)
# ===================================================================
# Provisions the client-hosting infrastructure on the dedicated EPYC
# host: the tenant Docker VM (docker01) with cloud-init bootstrap.
#
# SCOPE (what Terraform owns here):
#   - VM lifecycle on Proxmox (clone, sizing, disks, NICs, cloud-init)
#   - NOTHING inside the VMs: Docker, the edge proxy, tenants and
#     monitoring are Ansible's job (ansible/playbooks/hosting_bootstrap.yml)
#
# The Proxmox HOST is not managed by Terraform either — ZFS pools and
# Linux bridges are one-time host setup, scripted in the bare-metal
# runbook: .docs/hosting-architecture.md
#
# Usage:
#   export TF_VAR_pve_endpoint="https://<pve-mgmt-ip>:8006/"
#   export TF_VAR_pve_api_token="USER@realm!tokenid=uuid"   # from SOPS
#   terraform init
#   terraform plan      # human-gated: never apply without review
#   terraform apply
#
# Secrets come from environment variables (SOPS-rendered), never from
# state. See secrets/hosting.env.example.
# ===================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.115.0"
    }
  }
}
