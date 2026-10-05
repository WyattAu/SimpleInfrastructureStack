# ===================================================================
# Inputs — hosting platform
# ===================================================================
# Defaults encode the pilot architecture documented in
# .docs/hosting-architecture.md. Sizing vars exist so the same config
# can bring up docker02 on a second node without a rewrite.

variable "pve_endpoint" {
  description = "Proxmox VE API endpoint, e.g. https://192.168.0.50:8006/"
  type        = string
}

variable "pve_api_token" {
  description = "PVE API token in 'user@realm!tokenid=uuid' form (from SOPS)"
  type        = string
  sensitive   = true
}

variable "pve_insecure" {
  description = "Skip TLS verification for the PVE API (self-signed cert on fresh install)"
  type        = bool
  default     = true
}

variable "pve_ssh_user" {
  description = "SSH user for provider file operations (node-level)"
  type        = string
  default     = "root"
}

variable "pve_node" {
  description = "PVE node name the EPYC host was installed with"
  type        = string
  default     = "hosting01"
}

variable "template_vm_id" {
  description = "VM ID of the Ubuntu 24.04 cloud-image template (created per runbook)"
  type        = number
  default     = 9000
}

variable "datastore_id" {
  description = "PVE datastore for VM disks (ZFS pool created per runbook)"
  type        = string
  default     = "tank"
}

variable "snippet_datastore" {
  description = "Datastore for cloud-init snippet files"
  type        = string
  default     = "local"
}

# --- docker01 sizing -------------------------------------------------------

variable "docker01_cores" {
  description = "vCPUs for docker01 (16c/32t host: leave headroom for the node)"
  type        = number
  default     = 12
}

variable "docker01_memory_mib" {
  description = "Dedicated RAM for docker01 in MiB (128GB host: ~96GB)"
  type        = number
  default     = 98304
}

variable "docker01_root_gib" {
  description = "System disk size in GiB (cloned template's root disk, grown)"
  type        = number
  default     = 100
}

variable "docker01_data_gib" {
  description = "Tenant data disk in GiB (scsi1, mounted /srv by Ansible)"
  type        = number
  default     = 1500
}

# --- networking -------------------------------------------------------------

variable "mgmt_bridge" {
  description = "Linux bridge for management/WAN (vmbr0, host setup per runbook)"
  type        = string
  default     = "vmbr0"
}

variable "tenant_bridge" {
  description = "Internal bridge for tenant/backup traffic (vmbr1, host setup per runbook)"
  type        = string
  default     = "vmbr1"
}

variable "docker01_mgmt_use_dhcp" {
  description = "Get docker01's management IP from the business router via DHCP"
  type        = bool
  default     = true
}

variable "docker01_mgmt_ip" {
  description = "Static mgmt IP for docker01 (only used when mgmt_use_dhcp = false)"
  type        = string
  default     = ""
}

variable "docker01_mgmt_gateway" {
  description = "Static mgmt gateway (only used when mgmt_use_dhcp = false)"
  type        = string
  default     = ""
}

variable "tenant_net_cidr" {
  description = "Internal tenant/backup network"
  type        = string
  default     = "10.10.10.0/24"
}

variable "docker01_tenant_ip" {
  description = "docker01's address on the tenant bridge"
  type        = string
  default     = "10.10.10.10/24"
}

variable "ssh_admin_keys" {
  description = "Public keys allowed to SSH into docker01 as the admin user"
  type        = list(string)
}

variable "admin_username" {
  description = "Admin user created on docker01 by cloud-init (Ansible connects as this)"
  type        = string
  default     = "wyatt"
}

variable "timezone" {
  description = "Timezone for docker01"
  type        = string
  default     = "Europe/London"
}

variable "search_domain" {
  description = "DNS search domain for docker01"
  type        = string
  default     = "hosting.internal"
}
