#!/bin/bash
# ==============================================================================
# tenant-lifecycle.sh — business lifecycle for a tenant (research loop iter 10).
#
#   ./ops/tenant-lifecycle.sh <tenant> suspend|resume|deprovision
#
# The PaaS state of the art (Dokku/Coolify/CapRover) solves DEPLOYMENT
# lifecycle (apps create/destroy). A hosting BUSINESS needs BUSINESS
# lifecycle, which none of them ship:
#
#   suspend     non-payment / abuse hold: compose down, edge route removed,
#               a `.suspended` marker dropped (hosting-api reports it).
#               Data and backups untouched. Reversible in one command.
#   resume      undo a suspension: marker removed, stack up, route back.
#   deprovision final offsite backup + export receipt, then destructive
#               removal of the tenant (directory, edge route, quota).
# ==============================================================================
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
info() { echo -e "${GREEN}==${NC} $*"; }
warn() { echo -e "${YELLOW}!!${NC} $*"; }

TENANT_ROOT="${TENANT_ROOT:-/srv/tenants}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"

usage() {
    cat <<'USAGE'
Usage: tenant-lifecycle.sh <tenant> suspend|resume|deprovision

  suspend      stop the stack, remove the edge route, drop a .suspended marker
  resume       remove the marker, restore the edge route, start the stack
  deprovision  final offsite backup + receipt, then REMOVE the tenant
               (asks for the tenant name twice; not reversible)
USAGE
}

[ $# -eq 2 ] || { usage; die "need <tenant> and an action"; }
TENANT="$1"; ACTION="$2"
TENANT_DIR="${TENANT_ROOT}/${TENANT}"
[ -d "$TENANT_DIR" ] || die "no tenant directory at $TENANT_DIR"
[ -x "${TENANT_DIR}/compose.sh" ] || die "missing compose.sh (not a provisioned tenant?)"
case "$ACTION" in
    suspend|resume|deprovision) ;;
    *) usage; die "unknown action: $ACTION" ;;
esac

# Edge route block for this tenant, delimited by the provisioner's markers.
BEGIN_MARK="# BEGIN tenant:${TENANT}"
END_MARK="# END tenant:${TENANT}"

route_present() { [ -f "$CADDYFILE" ] && grep -qF "$BEGIN_MARK" "$CADDYFILE"; }

strip_route() {
    [ -f "$CADDYFILE" ] || return 0
    route_present || return 0
    local tmp; tmp=$(mktemp)
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0 ~ b {skip=1; next} $0 ~ e {skip=0; next} !skip' \
        "$CADDYFILE" > "$tmp"
    mv "$tmp" "$CADDYFILE"
    if command -v caddy >/dev/null 2>&1; then
        caddy validate --config "$CADDYFILE" >/dev/null 2>&1 \
            && systemctl reload caddy && info "edge reloaded (route removed)" \
            || warn "caddy reload failed after route removal - check manually"
    fi
}

restore_route() {
    # Re-insert the route the provisioner wrote, if it was stripped.
    route_present && { info "edge route already present"; return 0; }
    [ -f "$CADDYFILE" ] || { warn "no ${CADDYFILE}; add the route manually"; return 0; }
    DOMAIN=$(grep -E '^domain=' "${TENANT_DIR}/.credentials" 2>/dev/null | cut -d= -f2 || true)
    PORT=$(grep -E '^local_url=' "${TENANT_DIR}/.credentials" 2>/dev/null | grep -oE '[0-9]+$' || true)
    [ -n "$DOMAIN" ] && [ -n "$PORT" ] || { warn "cannot derive domain/port from .credentials; add the route manually"; return 0; }
    printf '\n%s\n%s {\n\treverse_proxy 127.0.0.1:%s\n}\n%s\n' \
        "$BEGIN_MARK" "$DOMAIN" "$PORT" "$END_MARK" >> "$CADDYFILE"
    if command -v caddy >/dev/null 2>&1; then
        caddy validate --config "$CADDYFILE" >/dev/null 2>&1 \
            && systemctl reload caddy && info "edge reloaded (route restored)" \
            || warn "caddy validate/reload FAILED - route written but not live"
    fi
}

case "$ACTION" in
    suspend)
        info "suspending ${TENANT} (data and backups are untouched)"
        "${TENANT_DIR}/compose.sh" stop || warn "stack was not running"
        strip_route
        touch "${TENANT_DIR}/.suspended"
        info "${TENANT} suspended - hosting-api now reports suspended: true"
        ;;

    resume)
        [ -f "${TENANT_DIR}/.suspended" ] || info "${TENANT} does not appear suspended; resuming anyway"
        rm -f "${TENANT_DIR}/.suspended"
        restore_route
        "${TENANT_DIR}/compose.sh" up -d || die "stack failed to start - CHECK NOW"
        info "${TENANT} resumed"
        ;;

    deprovision)
        echo -e "${RED}Deprovisioning removes ALL tenant data after one final offsite backup.${NC}"
        read -r -p "Type the tenant name to continue: " C1
        [ "$C1" = "$TENANT" ] || die "confirmation mismatch"
        read -r -p "This cannot be undone. Type the tenant name again: " C2
        [ "$C2" = "$TENANT" ] || die "confirmation mismatch"

        info "final backup (offsite)"
        if command -v tenant-backup.sh >/dev/null 2>&1; then
            tenant-backup.sh "$TENANT" --offsite || die "final backup FAILED - deprovision aborted; fix backups first"
        else
            die "tenant-backup.sh not in PATH - run the final backup manually before deprovisioning"
        fi

        SNAP_ID=$(restic snapshots --tag "tenant:${TENANT}" --latest 1 --json 2>/dev/null \
            | python3 -c 'import sys,json; s=json.load(sys.stdin); print(s[0]["short_id"] if s else "")' \
            || true)
        RECEIPT="${TENANT_DIR}/DEPROVISION-RECEIPT.txt"
        {
            echo "Tenant:      ${TENANT}"
            echo "Deprovisioned: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "Final snapshot: ${SNAP_ID:-UNKNOWN}"
            echo "Offsite copy:   yes (B2), retention per repo policy"
            echo "Restorable via: tenant-backup.sh ${TENANT} --restore ${SNAP_ID:-<id>}"
        } > "$RECEIPT"
        info "receipt written: ${RECEIPT}"
        echo "Copy this receipt out of the directory NOW - the next step deletes it."
        read -r -p "Receipt copied? Type the tenant name to proceed: " C3
        [ "$C3" = "$TENANT" ] || die "confirmation mismatch"

        info "stopping stack and removing the tenant"
        "${TENANT_DIR}/compose.sh" stop || true
        strip_route
        rm -f "${TENANT_DIR}/.suspended"
        rm -rf "${TENANT_DIR}"
        grep -qE "^${TENANT}:" /etc/projid 2>/dev/null && \
            sed -i "/^${TENANT}:/d" /etc/projid
        info "${TENANT} deprovisioned (final snapshot ${SNAP_ID:-UNKNOWN} remains restorable offsite)"
        ;;
esac
