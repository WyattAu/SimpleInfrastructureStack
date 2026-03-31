# ===================================================================
# SimpleInfrastructureStack - Terraform Infrastructure as Code
# ===================================================================
# Manages Docker networks and infrastructure prerequisites.
# Requires: terraform provider docker (https://registry.terraform.io/providers/kreuzwerker/docker)
#
# Usage:
#   terraform init
#   terraform plan
#   terraform apply
#
# Prerequisites:
#   - Docker daemon running and accessible
#   - Terraform >= 1.5.0
# ===================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

# Connect to the local Docker daemon
provider "docker" {
  host = "unix:///var/run/docker.sock"
}

# ===================================================================
# Docker Networks
# ===================================================================

# External network for Traefik-facing services
resource "docker_network" "traefik_net" {
  name   = "traefik_net"
  driver = "bridge"

  labels {
    label = "managed_by"
    value = "terraform"
  }

  # Prevent recreation if network already exists with same name
  lifecycle {
    create_before_destroy = false
  }
}

# Internal network for backend service-to-service communication
resource "docker_network" "backend_net" {
  name   = "backend_net"
  driver = "bridge"
  internal = true

  labels {
    label = "managed_by"
    value = "terraform"
  }

  lifecycle {
    create_before_destroy = false
  }
}

# Isolated network for CI workloads (Docker-in-Docker)
resource "docker_network" "ci_net" {
  name   = "ci_net"
  driver = "bridge"
  internal = false

  labels {
    label = "managed_by"
    value = "terraform"
  }

  lifecycle {
    create_before_destroy = false
  }
}

# ===================================================================
# Outputs
# ===================================================================

output "traefik_net_id" {
  value       = docker_network.traefik_net.id
  description = "ID of the traefik_net Docker network"
}

output "backend_net_id" {
  value       = docker_network.backend_net.id
  description = "ID of the backend_net Docker network"
}

output "ci_net_id" {
  value       = docker_network.ci_net.id
  description = "ID of the ci_net Docker network"
}
