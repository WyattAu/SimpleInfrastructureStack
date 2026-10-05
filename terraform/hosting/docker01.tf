# ===================================================================
# docker01 — the tenant Docker host VM
# ===================================================================
# Cloned from the Ubuntu 24.04 cloud-image template (runbook step 4),
# grown to pilot sizing, given a dedicated tenant-data disk, and
# bootstrapped by a cloud-init snippet. Everything after first boot is
# Ansible's job — this file only needs to produce a reachable, keyed VM.

# Cloud-init user data. Kept deliberately minimal: user + SSH key,
# guest agent, and a growpath for the data disk. Docker, nftables,
# fail2ban, Caddy, monitoring and tenant tooling are installed
# idempotently by Ansible so they can be re-run and audited.
resource "proxmox_virtual_environment_file" "docker01_user_data" {
  content_type = "snippets"
  datastore_id = var.snippet_datastore
  node_name    = var.pve_node

  source_raw {
    data = <<-CLOUDCONFIG
      #cloud-config
      hostname: docker01
      manage_etc_hosts: true
      timezone: ${var.timezone}
      users:
        - name: ${var.admin_username}
          groups: [adm, sudo]
          shell: /bin/bash
          sudo: ALL=(ALL) NOPASSWD:ALL
          lock_passwd: true
          ssh_authorized_keys:
            %{for key in var.ssh_admin_keys~}
            - ${key}
            %{endfor~}
      ssh_pwauth: false
      package_update: true
      packages:
        - qemu-guest-agent
        - cloud-guest-utils
      runcmd:
        - systemctl enable --now qemu-guest-agent
        # Partition-later approach: the data disk (scsi1) is formatted and
        # mounted by Ansible so a mistake there is a rerun, not a rebuild.
        - echo "docker01 cloud-init complete" > /var/log/cloud-init-runcmd.done
    CLOUDCONFIG

    file_name = "docker01-user-data.yaml"
  }
}

locals {
  # DHCP when on the business router; static when the node has a reserved
  # address. The CIDR length is fixed at /24 which matches the default
  # business-LAN layout in the runbook.
  mgmt_ip_config = var.docker01_mgmt_use_dhcp ? [
    {
      address = "dhcp"
      gateway = null
    }
    ] : [
    {
      address = "${var.docker01_mgmt_ip}/24"
      gateway = var.docker01_mgmt_gateway
    }
  ]
}

resource "proxmox_virtual_environment_vm" "docker01" {
  name      = "docker01"
  node_name = var.pve_node
  vm_id     = 110

  tags        = ["hosting", "docker", "tenants"]
  description = "Tenant Docker host — managed by Terraform (SIS terraform/hosting). Do not edit in the PVE UI."
  on_boot     = true

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = var.docker01_cores
    type  = "host"
  }

  memory {
    dedicated = var.docker01_memory_mib
    # Reclaim idle RAM for ZFS ARC on the host.
    floating = 8192
  }

  agent {
    enabled = true
    trim    = true
  }

  startup {
    order      = "2"
    up_delay   = "30"
    down_delay = "60"
  }

  # System disk: the template's cloned root disk, grown to pilot size.
  # Ubuntu's growpart expands the filesystem on first boot.
  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.docker01_root_gib
    ssd          = true
    discard      = "on"
    iothread     = true
  }

  # Tenant data disk (formatted and mounted at /srv by Ansible).
  disk {
    datastore_id = var.datastore_id
    interface    = "scsi1"
    size         = var.docker01_data_gib
    ssd          = true
    discard      = "on"
    iothread     = true
  }

  # NIC 1: management/WAN — reaches the business LAN and the internet.
  network_device {
    bridge   = var.mgmt_bridge
    firewall = true
  }

  # NIC 2: internal tenant/backup bridge — no gateway, no route to it
  # except from the host and future sibling VMs.
  network_device {
    bridge   = var.tenant_bridge
    firewall = true
  }

  initialization {
    datastore_id = var.snippet_datastore

    dns {
      domain  = var.search_domain
      servers = ["1.1.1.1", "8.8.8.8"]
    }

    dynamic "ip_config" {
      for_each = local.mgmt_ip_config
      content {
        ipv4 {
          address = ip_config.value.address
          gateway = ip_config.value.gateway
        }
      }
    }

    ip_config {
      ipv4 {
        address = var.docker01_tenant_ip
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.docker01_user_data.id
  }

  lifecycle {
    # Sizing changes are done with intent (and a maintenance window), not
    # by accident during a plan. Bump these consciously.
    ignore_changes = [cpu, memory, disk]
  }
}
