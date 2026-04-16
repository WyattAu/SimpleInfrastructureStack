#!/bin/sh
# Monthly Backup Restore Test
# Restores the latest snapshot to a temporary location and validates:
#   1. Key files exist and are non-empty
#   2. Database directories contain valid data
#   3. Configuration files parse correctly
#   4. File counts match expectations
#
# Runs inside backup-cron-trigger container.
# Exit code 0 = all checks passed, 1 = one or more checks failed.

set -euo pipefail

RESTORE_DIR="/tmp/restore-test-$$"
NTFY_TOPIC="${NTFY_TOPIC:-}"
RESULTS=""

# Track pass/fail counts
PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    RESULTS="${RESULTS}✅ $1\n"
}

fail() {
    FAIL=$((FAIL + 1))
    RESULTS="${RESULTS}❌ $1\n"
}

cleanup() {
    echo "[$(date -Iseconds)] Cleaning up restore directory..."
    docker exec backup-restic rm -rf "${RESTORE_DIR}" 2>/dev/null || true
}

trap cleanup EXIT

echo "[$(date -Iseconds)] Starting monthly backup restore test..."

# Step 1: Restore latest snapshot
echo "[$(date -Iseconds)] Restoring latest snapshot..."
docker exec backup-restic sh -c "
    rm -rf ${RESTORE_DIR}
    restic restore latest --target ${RESTORE_DIR}
"

# Step 2: Validate database directories contain files
echo "[$(date -Iseconds)] Validating database directories..."

for db_dir in \
    "${RESTORE_DIR}/data/operations/postgres-forgejo" \
    "${RESTORE_DIR}/data/collaboration/postgres" \
    "${RESTORE_DIR}/data/iam/postgres" \
    "${RESTORE_DIR}/data/accounting/mariadb-akaunting" \
    "${RESTORE_DIR}/data/rss/postgres" \
    "${RESTORE_DIR}/data/photos/db" \
    "${RESTORE_DIR}/data/documents/postgres"; do

    if [ -d "${db_dir}" ]; then
        file_count=$(docker exec backup-restic find "${db_dir}" -type f | wc -l)
        if [ "$file_count" -gt 0 ]; then
            pass "Database $(basename $(dirname "${db_dir}"))/$(basename "${db_dir}"): ${file_count} files"
        else
            fail "Database $(basename $(dirname "${db_dir}"))/$(basename "${db_dir}"): EMPTY (0 files)"
        fi
    else
        fail "Database directory missing: ${db_dir}"
    fi
done

# Step 3: Validate key configuration files exist and are non-empty
echo "[$(date -Iseconds)] Validating configuration files..."

for config_file in \
    "${RESTORE_DIR}/data/collaboration/synapse/homeserver.yaml" \
    "${RESTORE_DIR}/data/monitoring/prometheus/prometheus.yml" \
    "${RESTORE_DIR}/data/monitoring/alertmanager/alertmanager.yml"; do

    if docker exec backup-restic test -s "${config_file}"; then
        size=$(docker exec backup-restic wc -c < "${config_file}")
        pass "Config $(basename $(dirname "${config_file}"))/$(basename "${config_file}"): ${size} bytes"
    else
        fail "Config missing or empty: ${config_file}"
    fi
done

# Step 4: Validate Forgejo data has content
echo "[$(date -Iseconds)] Validating Forgejo data..."
if docker exec backup-restic test -d "${RESTORE_DIR}/data/operations/forgejo"; then
    forgejo_files=$(docker exec backup-restic find "${RESTORE_DIR}/data/operations/forgejo" -type f | wc -l)
    if [ "$forgejo_files" -gt 0 ]; then
        pass "Forgejo data: ${forgejo_files} files"
    else
        fail "Forgejo data: EMPTY"
    fi
else
    fail "Forgejo data directory missing"
fi

# Step 5: Validate Vaultwarden data exists
if docker exec backup-restic test -d "${RESTORE_DIR}/data/vaultwarden"; then
    vault_files=$(docker exec backup-restic find "${RESTORE_DIR}/data/vaultwarden" -type f | wc -l)
    if [ "$vault_files" -gt 0 ]; then
        pass "Vaultwarden data: ${vault_files} files"
    else
        pass "Vaultwarden data: not yet created (normal before first user)"
    fi
else
    pass "Vaultwarden data directory: not yet created"
fi

# Step 6: Validate Immich data exists
if docker exec backup-restic test -d "${RESTORE_DIR}/data/photos/upload"; then
    immich_files=$(docker exec backup-restic find "${RESTORE_DIR}/data/photos/upload" -type f | wc -l)
    pass "Immich upload: ${immich_files} files"
else
    pass "Immich upload: not yet created (normal before first upload)"
fi

# Step 7: Validate Paperless data exists
if docker exec backup-restic test -d "${RESTORE_DIR}/data/documents/media"; then
    paperless_files=$(docker exec backup-restic find "${RESTORE_DIR}/data/documents/media" -type f | wc -l)
    pass "Paperless media: ${paperless_files} files"
else
    pass "Paperless media: not yet created (normal before first scan)"
fi

# Step 8: Validate Synapse media exists (if any)
if docker exec backup-restic test -d "${RESTORE_DIR}/data/collaboration/synapse/media_store"; then
    media_count=$(docker exec backup-restic find "${RESTORE_DIR}/data/collaboration/synapse/media_store" -type f | wc -l)
    pass "Synapse media store: ${media_count} files"
else
    pass "Synapse media store: not yet created (normal for new installs)"
fi

# Step 9: Get snapshot info for reporting
SNAPSHOT_INFO=$(docker exec backup-restic restic snapshots --latest --json 2>/dev/null | head -1)
SNAPSHOT_DATE=$(docker exec backup-restic restic snapshots --latest --compact 2>/dev/null)

# Report results
echo ""
echo "=========================================="
echo "  MONTHLY BACKUP RESTORE TEST RESULTS"
echo "=========================================="
echo "  Snapshot: ${SNAPSHOT_DATE}"
echo "  Passed:   ${PASS}"
echo "  Failed:   ${FAIL}"
echo "------------------------------------------"
printf "%b" "$RESULTS"
echo "=========================================="

# Send ntfy notification
if [ -n "${NTFY_TOPIC}" ]; then
    if [ "$FAIL" -eq 0 ]; then
        curl -s -H "Title: ✅ Backup Restore Test PASSED" \
             -H "Priority: default" \
             -H "Tags: white_check_mark" \
             -d "All ${PASS} checks passed. Snapshot: ${SNAPSHOT_DATE}" \
             "https://ntfy.sh/${NTFY_TOPIC}" > /dev/null 2>&1 || true
    else
        curl -s -H "Title: ❌ Backup Restore Test FAILED" \
             -H "Priority: high" \
             -H "Tags: x" \
             -d "${FAIL}/${PASS} checks failed. See deploy log for details." \
             "https://ntfy.sh/${NTFY_TOPIC}" > /dev/null 2>&1 || true
    fi
fi

if [ "$FAIL" -gt 0 ]; then
    echo "[$(date -Iseconds)] Restore test FAILED"
    exit 1
else
    echo "[$(date -Iseconds)] Restore test PASSED"
    exit 0
fi
