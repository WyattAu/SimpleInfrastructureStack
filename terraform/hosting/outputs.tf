# Identifiers and addresses the Ansible bootstrap and the runbook need.

output "docker01_vm_id" {
  description = "Proxmox VM ID of docker01"
  value       = proxmox_virtual_environment_vm.docker01.vm_id
}

output "docker01_mgmt_ip" {
  description = "Management IP (DHCP: read it from the router or `qm guest cmd network-get-interfaces`)"
  value       = var.docker01_mgmt_use_dhcp ? "(DHCP — query the PVE guest agent after first boot)" : var.docker01_mgmt_ip
}

output "docker01_tenant_ip" {
  description = "docker01 on the internal tenant bridge (Ansible target via ProxyJump)"
  value       = var.docker01_tenant_ip
}

output "docker01_ssh_target" {
  description = "Ansible/SSH target string (ProxyJump through the PVE node)"
  value       = "${var.admin_username}@10.10.10.10"
}

output "next_steps" {
  description = "Ordered post-apply steps"
  value = [
    "1. Confirm the VM booted: qm guest cmd ${proxmox_virtual_environment_vm.docker01.vm_id} ping",
    "2. Point Ansible at it: ansible-playbook ansible/playbooks/hosting_bootstrap.yml",
    "3. Onboard the first tenant: ops/tenant-provision.sh (on docker01)",
  ]
}
