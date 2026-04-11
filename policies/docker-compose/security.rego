# ===================================================================
# Docker Compose Security Policy (Conftest/OPA)
# ===================================================================
# Usage: conftest test -p policies/ <docker-compose.yml>
# ===================================================================

package dockercompose.security

import future.keywords.in

# --- Exception lists (approved via ADR / security hardening decision) ---

# Init/one-shot containers: ephemeral, exit after task completes.
ephemeral_names := {"-init", "-chown"}

# Approved no-new-privileges exemptions (require elevated capabilities).
# - collabora: requires CLONE_NEWUSER for document sandboxing.
no_new_privileges_exempt := {"collabora"}

# Approved Docker socket RW exemptions (need full socket for container ops).
# - forgejo-runner: executes Docker builds and job containers.
# - woodpecker-agent: executes CI/CD pipeline containers.
docker_socket_rw_exempt := {"forgejo-runner", "woodpecker-agent"}

# --- Helpers ---

is_ephemeral(name) {
    some suffix in ephemeral_names
    endswith(name, suffix)
}

is_local_build(image) {
    not contains(image, "/")
    not contains(image, ".")
}

is_local_build(image) {
    startswith(image, "infra-")
}

has_no_new_privileges(security_opt) {
    some s in security_opt
    contains(s, "no-new-privileges")
}

# --- DENY rules ---
# Pattern: `svc := input.services[name]` binds both key and value,
# making `name` safe for use in negated expressions and sprintf output.

# DENY: No container should use privileged mode
deny_privileged[msg] {
    svc := input.services[name]
    svc.privileged == true
    msg := sprintf("Service '%s' uses privileged mode. This is a security risk.", [name])
}

# DENY: All long-running containers must have no-new-privileges
deny_no_new_privileges[msg] {
    svc := input.services[name]
    not is_ephemeral(name)
    not name in no_new_privileges_exempt
    not svc.security_opt
    msg := sprintf("Service '%s' lacks security_opt no-new-privileges:true", [name])
}

deny_no_new_privileges[msg] {
    svc := input.services[name]
    not is_ephemeral(name)
    not name in no_new_privileges_exempt
    not has_no_new_privileges(svc.security_opt)
    msg := sprintf("Service '%s' security_opt does not include no-new-privileges", [name])
}

# DENY: No image should use :latest tag (init containers and local builds exempt)
deny_latest_tag[msg] {
    svc := input.services[name]
    not is_ephemeral(name)
    image := svc.image
    endswith(image, ":latest")
    not is_local_build(image)
    msg := sprintf("Service '%s' uses unpinned image tag ':latest'", [name])
}

# DENY: All long-running services should have logging configured
deny_no_logging[msg] {
    svc := input.services[name]
    not is_ephemeral(name)
    not svc.logging
    msg := sprintf("Service '%s' has no logging configuration", [name])
}

# DENY: All long-running services should have resource limits
deny_no_resource_limits[msg] {
    svc := input.services[name]
    not is_ephemeral(name)
    not contains(name, "debug")
    not svc.deploy
    not svc.mem_limit
    msg := sprintf("Service '%s' has no resource limits", [name])
}

# WARN: Services with no health check (informational only)
warn_no_healthcheck[msg] {
    svc := input.services[name]
    not is_ephemeral(name)
    not contains(name, "debug")
    not svc.healthcheck
    msg := sprintf("Service '%s' has no health check", [name])
}

# DENY: No service should mount Docker socket with read-write (except approved)
deny_docker_socket_rw[msg] {
    svc := input.services[name]
    not name in docker_socket_rw_exempt
    some vol in svc.volumes
    contains(vol, "/var/run/docker.sock:/var/run/docker.sock")
    not contains(vol, ":ro")
    msg := sprintf("Service '%s' mounts Docker socket with read-write access", [name])
}

# DENY: No host path mounts with read-write to sensitive paths (excluding Docker socket)
deny_sensitive_host_mount[msg] {
    svc := input.services[name]
    some vol in svc.volumes
    sensitive_paths := ["/etc", "/root", "/sys/fs/cgroup"]
    mount_src := split(":", vol)[0]
    some p in sensitive_paths
    contains(mount_src, p)
    not contains(vol, ":ro")
    not contains(vol, "docker.sock")
    msg := sprintf("Service '%s' has read-write mount to sensitive path: %s", [name, vol])
}
