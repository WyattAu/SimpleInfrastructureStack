#!/bin/bash
# ==============================================================================
# tenant-backup.sh — snapshot one tenant's data directory into the restic repo.
#
#   ./ops/tenant-backup.sh <tenant> [--offsite]
#
# Tenants are tagged (`tenant:<slug>`) inside the existing restic repository
# rather than given their own repo. That keeps one set of credentials to
# manage, while still allowing a per-tenant restore or export on demand:
#
#   restore:  ops/tenant-backup.sh <tenant> --restore <snapshot-id>
#   export:   RESTIC_REPOSITORY=... restic export <snapshot-id> > tenant.tar
#
# Rationale: a tagged shared repo is far simpler to operate for the pilot.
# If a customer demands a dedicated repo/key for contractual reasons, create
# one with `restic init` and pass it via TENANT_RESTIC_REPO — see README.
# ==============================================================================
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
info() { echo -e "${GREEN}==${NC} $*"; }
warn() { echo -e "${YELLOW}!!${NC} $*"; }

TENANT_ROOT="${TENANT_ROOT:-/srv/tenants}"

usage() {
    cat <<'USAGE'
Usage: tenant-backup.sh <tenant> [--offsite] [--restore <snapshot-id>] [--list]

  --offsite            also copy the new snapshot to the offsite repo
  --restore <id>       restore that snapshot over the tenant's live data
                       (stops the stack first, restores, leaves it stopped)
  --list               list snapshots tagged for this tenant

Environment:
  RESTIC_REPOSITORY    live repo (default: the SIS live restic repo path)
  RESTIC_PASSWORD_FILE password file (default: $BACKUP_BASE/.restic-password)
  TENANT_RESTIC_REPO   per-tenant repo override (contractual isolation)
USAGE
}

TENANT=""; OFFSITE=0; RESTORE=""; LIST=0
while [ $# -gt 0 ]; do
    case "$1" in
        --offsite) OFFSITE=1; shift ;;
        --restore) RESTORE="${2:-}"; [ -n "$RESTORE" ] || die "--restore needs a snapshot id"; shift 2 ;;
        --list)    LIST=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*)        die "unknown option: $1" ;;
        *)         [ -z "$TENANT" ] || die "unexpected argument: $1"; TENANT="$1"; shift ;;
    esac
done

[ -n "$TENANT" ] || { usage; die "missing <tenant>"; }

TENANT_DIR="${TENANT_ROOT}/${TENANT}"
DATA_DIR="${TENANT_DIR}/data"

command -v restic >/dev/null || die "restic not found (run inside the backup-restic container or install it)"

BACKUP_BASE="${BACKUP_BASE:-/mnt/pool_HDD_x2/tank/datasources/sis/backups}"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-${BACKUP_BASE}/.restic-password}"
RESTIC_REPOSITORY="${TENANT_RESTIC_REPO:-${RESTIC_REPOSITORY:-${BACKUP_BASE}/restic-repo-new}}"
export RESTIC_REPOSITORY

[ -r "$RESTIC_PASSWORD_FILE" ] || die "cannot read restic password file: $RESTIC_PASSWORD_FILE"
[ -d "$DATA_DIR" ] || die "no tenant data directory at $DATA_DIR (provisioned? name correct?)"

info "tenant   $TENANT"
info "data     $DATA_DIR"
info "repo     $RESTIC_REPOSITORY"

# --- list mode --------------------------------------------------------------
if [ "$LIST" -eq 1 ]; then
    info "snapshots tagged tenant:$TENANT"
    restic snapshots --tag "tenant:${TENANT}" --compact || warn "no snapshots found"
    exit 0
fi

# --- restore mode -----------------------------------------------------------
if [ -n "$RESTORE" ]; then
    warn "restoring snapshot ${RESTORE} over ${DATA_DIR}"
    read -r -p "    This overwrites live tenant data. Type the tenant name to confirm: " CONFIRM
    [ "$CONFIRM" = "$TENANT" ] || die "confirmation did not match tenant name; aborting"

    info "stopping stack"
    COMPOSE="${TENANT_DIR}/compose.sh"
    [ -x "$COMPOSE" ] || die "missing $COMPOSE (tenant directory looks wrong)"
    "$COMPOSE" stop || warn "could not stop stack (was it running?)"

    info "restoring (this can take a while for large libraries)"
    restic restore "$RESTORE" --target "$DATA_DIR" --verify
    chown -R 65532:65532 "$DATA_DIR" 2>/dev/null || warn "could not chown restored data to 65532"

    info "done — start the stack when satisfied: $COMPOSE up -d"
    exit 0
fi

# --- backup mode ------------------------------------------------------------
# Stop the stack for a consistent snapshot. Postgres flushes on SIGTERM, and a
# file-level copy of a live database is not a backup you can trust.
COMPOSE="${TENANT_DIR}/compose.sh"
[ -x "$COMPOSE" ] || die "missing $COMPOSE (tenant directory looks wrong)"

if [ "${TENANT_NO_STOP:-0}" != "1" ]; then
    info "stopping stack for a consistent snapshot"
    "$COMPOSE" stop || warn "could not stop stack; snapshot may be inconsistent"
fi

info "creating snapshot (tag tenant:${TENANT})"
SNAP_JSON="$(restic backup "$DATA_DIR" \
    --tag "tenant:${TENANT}" \
    --tag "service:$(grep -E '^service=' "${TENANT_DIR}/.credentials" 2>/dev/null | cut -d= -f2 || echo unknown)" \
    --host "tenants" \
    --json)"

SNAP_ID="$(echo "$SNAP_JSON" | python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        continue
    if msg.get("message_type") == "summary":
        print(msg.get("snapshot_id", ""))
        break
')"

if [ -z "$SNAP_ID" ]; then
    die "restic did not report a snapshot id — treat this run as FAILED"
fi

info "snapshot ${SNAP_ID} created"

# Restart unless the caller opted out (e.g. a maintenance window).
if [ "${TENANT_NO_STOP:-0}" != "1" ]; then
    info "restarting stack"
    "$COMPOSE" up -d || warn "stack did not come back up cleanly — CHECK IT"
fi

# --- offsite ----------------------------------------------------------------
if [ "$OFFSITE" -eq 1 ]; then
    CRED_FILE="${BACKUP_BASE}/.offsite-credentials"
    [ -r "$CRED_FILE" ] || die "cannot read offsite credentials: $CRED_FILE"
    # shellcheck disable=SC1090
    source "$CRED_FILE"

    info "copying snapshot to offsite (B2)"
    RESTIC_REPOSITORY="s3:https://${B2_ENDPOINT}/${B2_BUCKET}/${B2_PREFIX:-repo}" \
    AWS_ACCESS_KEY_ID="${B2_ACCESS_KEY_ID}" \
    AWS_SECRET_ACCESS_KEY="${B2_SECRET_ACCESS_KEY}" \
    restic copy --tag "tenant:${TENANT}" 2>/dev/null ||
        RESTIC_REPOSITORY="s3:https://${B2_ENDPOINT}/${B2_BUCKET}/${B2_PREFIX:-repo}" \
        AWS_ACCESS_KEY_ID="${B2_ACCESS_KEY_ID}" \
        AWS_SECRET_ACCESS_KEY="${B2_SECRET_ACCESS_KEY}" \
        restic copy "${SNAP_ID}"

    info "offsite copy complete for ${SNAP_ID}"
fi

# --- prune (live repo only, never the offsite copy) -------------------------
if [ "${TENANT_PRUNE:-0}" = "1" ] && [ -z "${TENANT_RESTIC_REPO:-}" ]; then
    warn "pruning live repo (forget policy applies to ALL snapshots, not just this tenant)"
    restic forget --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune
fi

info "tenant backup OK: ${TENANT} ${SNAP_ID}"
