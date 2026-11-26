# tradebot (VM 130) — the operator's trading bot, co-located on hosting01.
#
# ISOLATION CONTRACT (iteration 30 risk review, 2026-11-26):
#   - SEPARATE guest: never shares a VM with tenant workloads (docker01 is
#     the paying tenant's production host).
#   - ONE NIC on the management bridge: no tenant bridge, no route into
#     10.10.10.0/24, NAT egress only.
#   - Venue API keys live as 0600 files in /home/wyatt/keys/ on the guest,
#     read at spawn. They never enter SIS (public), compose files, or logs.
#   - Trade-only API scopes; withdrawals disabled; IP-locked where the
#     venue supports it. Dry-run before live; spend caps + kill switch.
#
# Sizing: the R730 soaks clean (memtester/stress-ng/fio, iteration 30);
# 2c/4G leaves the node ample headroom for docker01/02 + the host ARC.

resource "proxmox_virtual_environment_vm" "tradebot" {
  name      = "tradebot"
  node_name = var.pve_node
  vm_id     = 130

  tags        = ["tradebot", "isolated"]
  description = "Operator tradebot — managed by Terraform (SIS terraform/hosting). Isolated: mgmt bridge only, no tenant bridge."
  on_boot     = true

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
    floating  = 0
  }

  agent {
    enabled = true
    trim    = true
  }

  startup {
    order      = "3"
    up_delay   = "15"
    down_delay = "30"
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = 32
    ssd          = true
    discard      = "on"
    iothread     = true
  }

  # NIC: management bridge only. No tenant bridge by contract.
  network_device {
    bridge   = var.mgmt_bridge
    firewall = false
  }

  initialization {
    datastore_id = var.snippet_datastore

    dns {
      domain  = var.search_domain
      servers = ["1.1.1.1", "8.8.8.8"]
    }

    # DHCP on the mgmt segment (the .0.x router side), like docker01's
    # mgmt. Pin it with a DHCP reservation once the MAC is known.
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    # cloud-init user data is managed OUT of terraform state (see
    # docker01.tf for the provider read-back bug). Deployed by ops tooling
    # to /var/lib/vz/snippets/tradebot-user-data.yaml.
    user_data_file_id = "local:snippets/tradebot-user-data.yaml"
  }
}
