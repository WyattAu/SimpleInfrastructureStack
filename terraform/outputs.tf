# ===================================================================
# SimpleInfrastructureStack - Terraform Outputs
# ===================================================================

output "networks" {
  value = {
    traefik_net = docker_network.traefik_net.name
    backend_net = docker_network.backend_net.name
    ci_net      = docker_network.ci_net.name
  }
  description = "Docker network names managed by Terraform"
}
