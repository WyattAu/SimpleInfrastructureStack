# ===================================================================
# docker02 — the staging Docker host VM
# ===================================================================
# Same template and shape as docker01, sized for staging only: 4 vCPU /
# 6 GiB / 60 GiB root, no dedicated data disk (staging data lives in the
# root disk and is treated as disposable). RAM budget on the 40 GiB host:
# PVE + ARC 8 GiB, docker01 20 GiB (8 GiB floor), docker02 6 GiB.
#
# Bootstrapped by Ansible with the same role; the playbook is limited to
# `docker02` and staging tenants live under /srv on the root disk.

locals {
  docker02_mgmt_ip_config = var.docker02_mgmt_use_dhcp ? [
    {
      address = "dhcp"
      gateway = null
    }
    ] : [
    {
      address = "${var.docker02_mgmt_ip}/24"
      gateway = var.docker02_mgmt_gateway
    }
  ]
}

resource "proxmox_virtual_environment_vm" "docker02" {
  name      = "docker02"
  node_name = var.pve_node
  vm_id     = 120

  tags        = ["hosting", "docker", "staging"]
  description = "Staging Docker host — managed by Terraform (SIS terraform/hosting). Do not edit in the PVE UI."
  on_boot     = true

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = var.docker02_cores
    type  = "host"
  }

  memory {
    dedicated = var.docker02_memory_mib
    floating  = 2048
  }

  agent {
    enabled = true
    trim    = true
  }

  startup {
    order      = "3"
    up_delay   = "30"
    down_delay = "60"
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.docker02_root_gib
    ssd          = true
    discard      = "on"
    iothread     = true
  }

  # NIC 1: management/WAN.
  network_device {
    bridge   = var.mgmt_bridge
    firewall = false
  }

  # NIC 2: internal tenant/backup bridge.
  network_device {
    bridge   = var.tenant_bridge
    firewall = false
  }

  initialization {
    datastore_id = var.snippet_datastore

    dns {
      domain  = var.search_domain
      servers = ["1.1.1.1", "8.8.8.8"]
    }

    dynamic "ip_config" {
      for_each = local.docker02_mgmt_ip_config
      content {
        ipv4 {
          address = ip_config.value.address
          gateway = ip_config.value.gateway
        }
      }
    }

    ip_config {
      ipv4 {
        address = var.docker02_tenant_ip
      }
    }

    # Out-of-state snippet, same reason as docker01.tf.
    user_data_file_id = "local:snippets/docker02-user-data.yaml"
  }

  lifecycle {
    ignore_changes = [cpu, memory, disk]
  }
}
