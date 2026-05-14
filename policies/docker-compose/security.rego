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
# - wireguard: requires privileged mode for VPN tunnel management.
# - taiga-back, taiga-async: entrypoint uses gosu to drop to taiga user,
#   which requires setuid capability blocked by no-new-privileges.
no_new_privileges_exempt := {"collabora", "wireguard", "taiga-back", "taiga-async"}

# Approved :latest tag exemptions (free-tier images with no version tags).
# - cgr.dev/chainguard/*: distroless images, free tier only provides :latest.
#   Renovate tracks by digest (pinDigests) to detect image changes.
latest_tag_exempt_prefixes := {"cgr.dev/chainguard/"}

# Approved privileged mode exemptions (require full host capabilities).
# - wireguard: requires NET_ADMIN, SYS_MODULE for VPN tunnel management.
privileged_exempt := {"wireguard"}

# Approved Docker socket RW exemptions (need full socket for container ops).
# - forgejo-runner: executes Docker builds and job containers.
docker_socket_rw_exempt := {"forgejo-runner"}

# --- Helpers ---

is_ephemeral(name) {
    some suffix in ephemeral_names
    endswith(name, suffix)
}

# Local builds: images built from Dockerfile (no registry path).
# Identified by "infra-" prefix for project-built images.
is_local_build(image) {
    startswith(image, "infra-")
}

# resource_limits is true when deploy.resources.limits contains at least
# one key (e.g. memory, cpus). An empty limits block still counts.
resource_limits(svc) {
    limits := svc.deploy.resources.limits
    count(limits) > 0
}

has_no_new_privileges(security_opt) {
    some s in security_opt
    contains(s, "no-new-privileges")
}

# --- DENY rules ---
# Pattern: `svc := input.services[name]` binds both key and value,
# making `name` safe for use in negated expressions and sprintf output.

# DENY: No container should use privileged mode (except approved exemptions)
deny_privileged[msg] {
    svc := input.services[name]
    svc.privileged == true
    not is_privileged_exempt(name)
    msg := sprintf("Service '%s' uses privileged mode. This is a security risk.", [name])
}

is_privileged_exempt(name) {
    some suffix in privileged_exempt
    endswith(name, suffix)
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

# DENY: No image should use :latest tag (init containers, local builds, and Chainguard exempt)
deny_latest_tag[msg] {
    svc := input.services[name]
    not is_ephemeral(name)
    image := svc.image
    endswith(image, ":latest")
    not is_local_build(image)
    not is_latest_tag_exempt(image)
    msg := sprintf("Service '%s' uses unpinned image tag ':latest'", [name])
}

is_latest_tag_exempt(image) {
    some prefix in latest_tag_exempt_prefixes
    startswith(image, prefix)
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
    not resource_limits(svc)
    msg := sprintf("Service '%s' has no resource limits", [name])
}

# WARN: Services with no health check (informational only)
# Exempt: containers named "*-init" (ephemeral), and distroless images
# that have no shell to run healthcheck commands.
warn_no_healthcheck[msg] {
    svc := input.services[name]
    not is_ephemeral(name)
    not contains(name, "debug")
    not svc.healthcheck
    not is_distroless_no_shell(name)
    msg := sprintf("Service '%s' has no health check", [name])
}

# Distroless containers with no shell cannot run CMD-based healthchecks.
# These rely on Traefik's own health checking via the reverse proxy,
# VictoriaMetrics scrape targets, or log-based monitoring.
distroless_no_shell_names := {"taiga-gateway", "redis-exporter", "cloudflare-ddns",
  "watchtower", "matrix-hookshot", "immich-ml"}

is_distroless_no_shell(name) {
    some n in distroless_no_shell_names
    name == n
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

# === Helper functions (must be defined before rules that use them) ===

# Check if a string looks like a port number (all digits, at least one char).
# Used to distinguish image tags from port numbers (e.g., image:5000).
has_digits_only(s) {
    count(s) > 0
    not regex.match("[^0-9]", s)
}

# === DENY rules ===
# Reservations help Docker place containers on nodes with sufficient resources.
warn_no_memory_reservation[msg] {
    svc := input.services[name]
    not is_ephemeral(name)
    svc.deploy
    svc.deploy.resources.limits.memory
    not svc.deploy.resources.reservations
    msg := sprintf("Service '%s' has memory limit but no reservation", [name])
}

# DENY: Images without any tag (e.g. "postgres" instead of "postgres:16").
# Exemptions: local builds (infra-*), ephemeral containers, and Chainguard.
deny_untagged_image[msg] {
    svc := input.services[name]
    not is_ephemeral(name)
    image := svc.image
    not is_local_build(image)
    not is_latest_tag_exempt(image)
    not contains(image, ":")
    msg := sprintf("Service '%s' uses untagged image '%s' (no version pin)", [name, image])
}

# NOTE: deny_untagged_image rule — deny_latest_tag catches ":latest",
# and deny_untagged_image catches images with no tag at all.

# Approved cap_add exemptions (require specific Linux capabilities).
# - wireguard: requires NET_ADMIN, SYS_MODULE for VPN tunnel management.
cap_add_exempt := {"wireguard"}

# Approved user directive exemptions (image entrypoints manage users).
# - postgres, mariadb, redis, valkey, mongo: images use dedicated runtime users
#   via their own entrypoint scripts; explicit user breaks health checks or data dirs.
user_directive_exempt := {"postgres", "mariadb", "redis", "valkey", "mongo"}

# Approved read_only exemptions (need writable filesystem at runtime).
# - postgres, mariadb, redis, valkey, mongo: database engines write to data dirs.
# - collabora: document rendering requires writable tmp and font cache.
# - taiga-back, taiga-async: Python apps need writable virtualenv/cache.
# - immich-ml: ML inference needs writable model cache.
# - vaultwarden: needs writable data dir and RSA key generation.
# - akaunting: PHP app needs writable storage and bootstrap cache.
# - synapse: homeserver needs writable media store and signing keys.
read_only_exempt := {"postgres", "mariadb", "redis", "valkey", "mongo",
  "collabora", "taiga-back", "taiga-async", "immich-ml",
  "vaultwarden", "akaunting", "synapse"}

is_cap_add_exempt(name) {
    some suffix in cap_add_exempt
    endswith(name, suffix)
}

is_user_directive_exempt(name) {
    some suffix in user_directive_exempt
    endswith(name, suffix)
}

is_read_only_exempt(name) {
    some suffix in read_only_exempt
    endswith(name, suffix)
}

# WARN: Services with cap_add should also have cap_drop: ALL (except approved).
warn_no_cap_drop[msg] {
    svc := input.services[name]
    not is_ephemeral(name)
    not is_cap_add_exempt(name)
    svc.cap_add
    not svc.cap_drop
    msg := sprintf("Service '%s' has cap_add but no cap_drop: ALL", [name])
}

# WARN: Services should run as non-root via user directive or entrypoint
# (except images that manage their own runtime user).
warn_no_user_directive[msg] {
    svc := input.services[name]
    not is_ephemeral(name)
    not is_user_directive_exempt(name)
    not svc.user
    msg := sprintf("Service '%s' has no user directive — consider PUID/PGID or explicit UID", [name])
}

# WARN: Services should use read_only: true with tmpfs for writable paths
# (except images that require persistent writable filesystem).
warn_no_read_only[msg] {
    svc := input.services[name]
    not is_ephemeral(name)
    not is_read_only_exempt(name)
    not svc.read_only
    msg := sprintf("Service '%s' is not read_only — consider read_only: true with tmpfs mounts", [name])
}

# WARN: Long-running services should have a pids_limit to prevent fork bombs.
# Per the Compose Specification, pids goes under deploy.resources.limits.
warn_no_pids_limit[msg] {
    svc := input.services[name]
    not is_ephemeral(name)
    not contains(name, "debug")
    svc.deploy
    svc.deploy.resources.limits
    not svc.deploy.resources.limits.pids
    msg := sprintf("Service '%s' has no pids limit -- consider adding pids: 100 under deploy.resources.limits", [name])
}
