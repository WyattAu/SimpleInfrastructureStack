# ===================================================================
# Docker Compose Security Policy (Conftest/OPA)
# ===================================================================
# Usage: conftest test -p policies/ <docker-compose.yml>
# ===================================================================

package dockercompose.security

import future.keywords.in
import future.keywords.every

# --- Exception lists (approved via ADR / security hardening decision) ---
# Containers in these lists are exempt from specific checks.
# Each exemption must reference a justification.

# Init/one-shot containers: ephemeral, exit after task completes.
# Not worth hardening — they run as root briefly to create dirs or generate config.
ephemeral_names := {"-init", "-chown"}

# Approved no-new-privileges exemptions (require elevated capabilities by design).
# - collabora: requires CLONE_NEWUSER for document sandboxing.
no_new_privileges_exempt := {"collabora"}

# Approved Docker socket RW exemptions (need full socket access for container ops).
# - Forgejo runner: executes Docker builds and job containers.
# - Woodpecker agent: executes CI/CD pipeline containers.
docker_socket_rw_exempt := {"forgejo-runner", "woodpecker-agent"}

# Helper: is this service an ephemeral init/chown container?
is_ephemeral(name) {
    some suffix in ephemeral_names
    endswith(name, suffix)
}

# Helper: detect locally-built images (no registry path, or named infra-*).
is_local_build(image) {
    not contains(image, "/")
    not contains(image, ".")
}

is_local_build(image) {
    startswith(image, "infra-")
}

# DENY: No container should use privileged mode
deny_privileged[msg] {
    some name
    input.services[name].privileged == true
    msg := sprintf("Service '%s' uses privileged mode. This is a security risk.", [name])
}

# DENY: All long-running containers must have no-new-privileges
deny_no_new_privileges[msg] {
    some name
    not is_ephemeral(name)
    not name in no_new_privileges_exempt
    not input.services[name].security_opt
    msg := sprintf("Service '%s' lacks security_opt no-new-privileges:true", [name])
}

deny_no_new_privileges[msg] {
    some name
    not is_ephemeral(name)
    not name in no_new_privileges_exempt
    security_opt := input.services[name].security_opt
    not any([s | s == security_opt[_]; contains(s, "no-new-privileges")])
    msg := sprintf("Service '%s' security_opt does not include no-new-privileges", [name])
}

# DENY: No image should use :latest tag
# Exemptions: init/chown containers (pinned in versions.env separately),
# and locally-built images (image name starts with infra- or contains no registry path).
deny_latest_tag[msg] {
    some name
    not is_ephemeral(name)
    image := input.services[name].image
    endswith(image, ":latest")
    not is_local_build(image)
    msg := sprintf("Service '%s' uses unpinned image tag ':latest'", [name])
}

# DENY: All long-running services should have logging configured
deny_no_logging[msg] {
    some name
    not is_ephemeral(name)
    not input.services[name].logging
    msg := sprintf("Service '%s' has no logging configuration", [name])
}

# DENY: All long-running services should have resource limits
deny_no_resource_limits[msg] {
    some name
    not is_ephemeral(name)
    not contains(name, "debug")
    not input.services[name].deploy
    not input.services[name].mem_limit
    msg := sprintf("Service '%s' has no resource limits", [name])
}

# WARN: Services with no health check (informational only)
warn_no_healthcheck[msg] {
    some name
    not is_ephemeral(name)
    not contains(name, "debug")
    not input.services[name].healthcheck
    msg := sprintf("Service '%s' has no health check", [name])
}

# DENY: No service should mount Docker socket with read-write (except approved)
deny_docker_socket_rw[msg] {
    some name
    not name in docker_socket_rw_exempt
    some volume in input.services[name].volumes
    contains(volume, "/var/run/docker.sock:/var/run/docker.sock")
    not contains(volume, ":ro")
    msg := sprintf("Service '%s' mounts Docker socket with read-write access", [name])
}

# DENY: No host path mounts with read-write to sensitive paths (excluding Docker socket)
deny_sensitive_host_mount[msg] {
    some name
    some volume in input.services[name].volumes
    sensitive_paths := ["/etc", "/root", "/sys/fs/cgroup"]
    mount_src := split(":", volume)[0]
    some p in sensitive_paths
    contains(mount_src, p)
    not contains(volume, ":ro")
    # Docker socket mounts are handled by deny_docker_socket_rw
    not contains(volume, "docker.sock")
    msg := sprintf("Service '%s' has read-write mount to sensitive path: %s", [name, volume])
}
