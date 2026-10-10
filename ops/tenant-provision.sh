#!/bin/bash
# ==============================================================================
# tenant-provision.sh — provision a customer tenant from a template.
#
#   ./ops/tenant-provision.sh <tenant> <service> --domain <fqdn> [options]
#
# Creates an isolated per-tenant stack under $TENANT_ROOT with freshly
# generated credentials, then (optionally) starts it. Every tenant gets its
# own Postgres, its own volumes and its own bind-mounted data directory, so
# backup/restore and teardown are scoped to one directory.
#
# Idempotency: refuses to overwrite an existing tenant unless --force.
# Nothing is deleted by --force; it only regenerates .env, which rotates
# credentials and therefore requires a `docker compose up -d --force-recreate`.
# ==============================================================================
set -euo pipefail

TENANT_ROOT="${TENANT_ROOT:-/srv/tenants}"
PORT_BASE="${PORT_BASE:-18080}"
TZ_DEFAULT="${TZ:-Europe/London}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_ROOT="${SCRIPT_DIR}/tenants/templates"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'

die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
info() { echo -e "${GREEN}==${NC} $*"; }
warn() { echo -e "${YELLOW}!!${NC} $*"; }

usage() {
    cat <<'USAGE'
Usage: tenant-provision.sh <tenant> <service> --domain <fqdn> [options]

Required:
  <tenant>            short slug, e.g. acme
  <service>           template name (see ops/tenants/templates/)
  --domain <fqdn>     public hostname, e.g. files.acme.example

Options:
  --admin-user <u>    initial superuser (default: admin)
  --port <n>          local publish port (default: first free from 18080)
  --tz <zone>         container timezone (default: Europe/London)
  --no-start          prepare everything but do not start containers
  --force             regenerate .env for an existing tenant (rotates secrets)
  -h, --help          this message

Example:
  ./ops/tenant-provision.sh acme documents --domain docs.acme.example
USAGE
}

# --- argument parsing -------------------------------------------------------
TENANT=""; SERVICE=""; DOMAIN=""; ADMIN_USER="admin"; PORT=""; TZ="$TZ_DEFAULT"
START=1; FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)     DOMAIN="${2:-}"; shift 2 ;;
        --admin-user) ADMIN_USER="${2:-}"; shift 2 ;;
        --port)       PORT="${2:-}"; shift 2 ;;
        --tz)         TZ="${2:-}"; shift 2 ;;
        --no-start)   START=0; shift ;;
        --force)      FORCE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        -*)           die "unknown option: $1 (try --help)" ;;
        *)            if [ -z "$TENANT" ]; then TENANT="$1"
                      elif [ -z "$SERVICE" ]; then SERVICE="$1"
                      else die "unexpected argument: $1"; fi; shift ;;
    esac
done

[ -n "$TENANT" ]   || { usage; die "missing <tenant>"; }
[ -n "$SERVICE" ]  || { usage; die "missing <service>"; }
[ -n "$DOMAIN" ]   || { usage; die "missing --domain"; }

# --- validate inputs --------------------------------------------------------
[[ "$TENANT"   =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || die "tenant must be lowercase alphanumeric/dash (got: $TENANT)"
[[ "$DOMAIN"   =~ ^[a-z0-9.-]+$ ]]            || die "domain looks invalid (got: $DOMAIN)"

TEMPLATE_DIR="${TEMPLATE_ROOT}/${SERVICE}"
[ -d "$TEMPLATE_DIR" ] || die "no template '$SERVICE'. Available: $(ls "$TEMPLATE_ROOT" 2>/dev/null | tr '\n' ' ')"
[ -f "${TEMPLATE_DIR}/docker-compose.yml" ] || die "template $SERVICE has no docker-compose.yml"
[ -f "${TEMPLATE_DIR}/env.template" ] || die "template $SERVICE has no env.template"

command -v docker >/dev/null || die "docker not found"
docker compose version >/dev/null 2>&1 || die "docker compose v2 not available"

TENANT_DIR="${TENANT_ROOT}/${TENANT}"
ENV_FILE="${TENANT_DIR}/.env"

if [ -e "$TENANT_DIR" ] && [ "$FORCE" -ne 1 ]; then
    die "tenant '$TENANT' already exists at $TENANT_DIR (use --force to rotate credentials)"
fi

# --- pick a free port -------------------------------------------------------
port_in_use() { ss -ltn "sport = :$1" 2>/dev/null | tail -n +2 | grep -q .; }
if [ -z "$PORT" ]; then
    PORT="$PORT_BASE"
    while port_in_use "$PORT"; do
        PORT=$((PORT + 1))
        [ "$PORT" -gt 65535 ] && die "no free port found from $PORT_BASE"
    done
fi
port_in_use "$PORT" && die "port $PORT is already in use"

# --- generate secrets -------------------------------------------------------
gen_hex()   { openssl rand -hex "$1"; }
gen_pass()  { openssl rand -base64 24 | tr -d '/+=' | cut -c1-28; }

POSTGRES_PASSWORD="$(gen_hex 24)"
REDIS_PASSWORD="$(gen_hex 24)"
PAPERLESS_SECRET_KEY="$(gen_hex 32)"
ADMIN_PASSWORD="$(gen_pass)"

info "generating credentials for tenant '$TENANT' (service: $SERVICE)"

# --- lay out the tenant directory ------------------------------------------
info "creating $TENANT_DIR"
mkdir -p "${TENANT_DIR}/data"

cp "${TEMPLATE_DIR}/docker-compose.yml" "${TENANT_DIR}/docker-compose.yml"
cp "${TEMPLATE_DIR}/versions.env" "${TENANT_DIR}/versions.env"

# Render env.template -> .env
sed \
    -e "s|__TENANT__|${TENANT}|g" \
    -e "s|__DOMAIN__|${DOMAIN}|g" \
    -e "s|__TZ__|${TZ}|g" \
    -e "s|__TENANT_DATA_DIR__|${TENANT_DIR}/data|g" \
    -e "s|__APP_PORT__|${PORT}|g" \
    -e "s|__POSTGRES_PASSWORD__|${POSTGRES_PASSWORD}|g" \
    -e "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|g" \
    -e "s|__PAPERLESS_SECRET_KEY__|${PAPERLESS_SECRET_KEY}|g" \
    -e "s|__ADMIN_USER__|${ADMIN_USER}|g" \
    -e "s|__ADMIN_PASSWORD__|${ADMIN_PASSWORD}|g" \
    "${TEMPLATE_DIR}/env.template" > "$ENV_FILE"

chmod 600 "$ENV_FILE"

# Compose only auto-loads .env, so image pins from versions.env would silently
# resolve to empty tags. Wrap compose so both files are always passed, in the
# same order SIS uses (secrets first, version pins second).
cat > "${TENANT_DIR}/compose.sh" <<'WRAPPER'
#!/bin/bash
# Generated by ops/tenant-provision.sh — use this instead of bare `docker compose`.
# Loads credentials (.env) and image pins (versions.env) in the correct order.
set -euo pipefail
cd "$(dirname "$0")"
exec docker compose --env-file .env --env-file versions.env "$@"
WRAPPER
chmod +x "${TENANT_DIR}/compose.sh"

# Paperless writes as 65532; make the data dir traversable/writable for it.
chown -R 65532:65532 "${TENANT_DIR}/data" 2>/dev/null || \
    warn "could not chown data dir to 65532:65532 (run as root or fix ownership manually)"

# Credentials summary for the operator (chmod 600, never committed).
cat > "${TENANT_DIR}/.credentials" <<CREDS
# TENANT ${TENANT} — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Keep this file out of version control and out of shared drives.
service=${SERVICE}
domain=${DOMAIN}
local_url=http://127.0.0.1:${PORT}
initial_admin_user=${ADMIN_USER}
initial_admin_password=${ADMIN_PASSWORD}
postgres_password=${POSTGRES_PASSWORD}
redis_password=${REDIS_PASSWORD}
paperless_secret_key=${PAPERLESS_SECRET_KEY}
CREDS
chmod 600 "${TENANT_DIR}/.credentials"

cat > "${TENANT_DIR}/.gitignore" <<'GITIGNORE'
.env
.credentials
data/
GITIGNORE

# --- start ------------------------------------------------------------------
if [ "$START" -eq 1 ]; then
    info "starting stack (compose.sh up -d)"
    "${TENANT_DIR}/compose.sh" up -d
    info "waiting for containers to report healthy (up to 5 min)..."
    timeout 300 "${TENANT_DIR}/compose.sh" ps --format 'table {{.Name}}\t{{.Status}}' || true
else
    info "skipping start (--no-start)"
fi

# --- per-tenant disk quota (research loop iter 9) ---------------------------
# ext4 project quota: one tenant cannot fill the shared data disk for
# everyone. Project id = stable numeric hash of the tenant slug; the quota
# is enforced with xfs_quota (which administers ext4 project quotas).
TENANT_QUOTA_GB="${TENANT_QUOTA_GB:-100}"
if [ "${TENANT_QUOTA_GB}" != "0" ] && command -v xfs_quota >/dev/null 2>&1; then
    PROJ_ID=$(echo -n "$TENANT" | sum | awk '{print $1}')
    PROJ_FILE=/etc/projid
    touch "$PROJ_FILE"; chmod 644 "$PROJ_FILE"
    grep -qE "^${TENANT}:" "$PROJ_FILE" || echo "${TENANT}:${PROJ_ID}" >> "$PROJ_FILE"
    chattr -p "${PROJ_ID}" -P "${TENANT_DIR}" 2>/dev/null \
        || warn "could not set project id on ${TENANT_DIR} (prjquota mounted?)"
    if ! xfs_quota -x -c "project -s ${TENANT} ${TENANT_DIR}" "${TENANT_ROOT}" 2>/dev/null; then
        warn "project setup failed for ${TENANT} - quota NOT enforced"
    fi
    xfs_quota -x -c "limit -p bhard=${TENANT_QUOTA_GB}g ${TENANT}" "${TENANT_ROOT}" 2>/dev/null \
        && info "disk quota: ${TENANT_QUOTA_GB}G hard for ${TENANT}" \
        || warn "could not set project limit for ${TENANT} - quota NOT enforced"
else
    warn "TENANT_QUOTA_GB=0 or xfs_quota missing - NO disk quota for ${TENANT}"
fi

# --- edge route (research loop iter 2: API-driven onboarding) ---------------
# Idempotently add the tenant's reverse-proxy route to the Caddyfile and
# gracefully reload (Caddy reloads are zero-downtime: connections drain,
# sockets hand over). Removes the manual "add a router and reload" handoff
# step, which is where tenant routes went stale before this.
CADDYFILE=/etc/caddy/Caddyfile
BEGIN_MARK="# BEGIN tenant:${TENANT}"
END_MARK="# END tenant:${TENANT}"
ROUTE_BLOCK="${BEGIN_MARK}
${DOMAIN} {
	reverse_proxy 127.0.0.1:${PORT}
}
${END_MARK}"
if [ -f "$CADDYFILE" ]; then
    if grep -qF "$BEGIN_MARK" "$CADDYFILE"; then
        # Replace the existing block atomically (new file + mv).
        TMP_CADDY=$(mktemp)
        awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v r="$ROUTE_BLOCK" '
            $0 ~ b {print r; skip=1; next}
            $0 ~ e {skip=0; next}
            !skip {print}' "$CADDYFILE" > "$TMP_CADDY"
        mv "$TMP_CADDY" "$CADDYFILE"
        info "edge route for ${DOMAIN} updated"
    else
        printf '\n%s\n' "$ROUTE_BLOCK" >> "$CADDYFILE"
        info "edge route for ${DOMAIN} appended"
    fi
    if command -v caddy >/dev/null 2>&1; then
        if caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
            systemctl reload caddy && info "edge reloaded (zero-downtime)" \
                || warn "caddy reload failed - route is in the file; check: systemctl status caddy"
        else
            warn "caddy validate FAILED against ${CADDYFILE} - NOT reloading; fix the file manually"
        fi
    else
        warn "caddy binary not found; route written but not reloaded"
    fi
else
    warn "${CADDYFILE} not found - add the route for ${DOMAIN} -> 127.0.0.1:${PORT} manually"
fi

# --- handoff ----------------------------------------------------------------
cat <<HANDOFF

$(printf '=%.0s' {1..70})
 Tenant '${TENANT}' provisioned (service: ${SERVICE})
$(printf '=%.0s' {1..70})
 directory   ${TENANT_DIR}
 hostname    ${DOMAIN}
 local port  127.0.0.1:${PORT}
 credentials ${TENANT_DIR}/.credentials   (chmod 600)

 Next steps
   1. DNS: point ${DOMAIN} at this host (A record, or a proxied CNAME
      if you terminate at Cloudflare).
   2. Edge proxy: route added and reloaded automatically (if /etc/caddy/
      Caddyfile exists); verify with: curl -fsS https://${DOMAIN}/
   3. Backup:  ops/tenant-backup.sh ${TENANT}
      and register it in the backup timer (README covers this).
   4. Hand over: walk the customer through .docs/tenant-onboarding.md
      and rotate the initial admin password.

 Verify
   curl -fsS http://127.0.0.1:${PORT}/ >/dev/null && echo reachable
   ${TENANT_DIR}/compose.sh logs --tail 50 | grep -iE 'error|fatal'
$(printf '=%.0s' {1..70})
HANDOFF
