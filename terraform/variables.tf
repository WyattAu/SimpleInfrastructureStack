# ===================================================================
# SimpleInfrastructureStack - Terraform Variables
# ===================================================================

variable "docker_host" {
  description = "Docker daemon socket path"
  type        = string
  default     = "unix:///var/run/docker.sock"
}
