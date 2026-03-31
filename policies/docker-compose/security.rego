# ===================================================================
# Docker Compose Security Policy (Conftest/OPA)
# ===================================================================
# Usage: conftest test -p policies/ <docker-compose.yml>
# ===================================================================

package dockercompose.security

# DENY: No container should use privileged mode (except known exceptions)
deny_privileged[msg] {
  input.services[name].privileged == true
  name != "docker-in-docker"
  msg := sprintf("Service '%s' uses privileged mode. This is a security risk.", [name])
}

# DENY: All containers must have no-new-privileges
deny_no_new_privileges[msg] {
  not input.services[name].security_opt
  msg := sprintf("Service '%s' lacks security_opt no-new-privileges:true", [name])
}

deny_no_new_privileges[msg] {
  security_opt := input.services[name].security_opt
  not any([s | s == security_opt[_]; contains(s, "no-new-privileges")])
  msg := sprintf("Service '%s' security_opt does not include no-new-privileges", [name])
}

# DENY: No image should use :latest tag
deny_latest_tag[msg] {
  image := input.services[name].image
  endswith(image, ":latest")
  msg := sprintf("Service '%s' uses unpinned image tag ':latest'", [name])
}

# DENY: All services should have logging configured
deny_no_logging[msg] {
  not input.services[name].logging
  msg := sprintf("Service '%s' has no logging configuration", [name])
}

# DENY: All stateful services should have resource limits
deny_no_resource_limits[msg] {
  not input.services[name].deploy
  not input.services[name].mem_limit
  # Skip init containers (ephemeral)
  not contains(name, "-init")
  not contains(name, "-chown")
  not contains(name, "debug")
  msg := sprintf("Service '%s' has no resource limits", [name])
}

# WARN: Services with no health check
warn_no_healthcheck[msg] {
  not input.services[name].healthcheck
  not contains(name, "-init")
  not contains(name, "-chown")
  not contains(name, "debug")
  msg := sprintf("Service '%s' has no health check", [name])
}

# DENY: No service should mount Docker socket with read-write
deny_docker_socket_rw[msg] {
  volume := input.services[name].volumes[_]
  contains(volume, "/var/run/docker.sock:/var/run/docker.sock")
  not contains(volume, ":ro")
  msg := sprintf("Service '%s' mounts Docker socket with read-write access", [name])
}

# DENY: No host path mounts with read-write to sensitive paths
deny_sensitive_host_mount[msg] {
  volume := input.services[name].volumes[_]
  sensitive_paths := ["/etc", "/var/run", "/root", "/sys/fs/cgroup"]
  mount_src := split(":", volume)[0]
  any([contains(mount_src, p) | p := sensitive_paths[_]])
  not contains(volume, ":ro")
  not contains(volume, "docker.sock")
  msg := sprintf("Service '%s' has read-write mount to sensitive path: %s", [name, volume])
}
