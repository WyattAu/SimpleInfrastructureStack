#!/usr/bin/env bash
# Monthly Backup Restore Test
# Restores the latest snapshot per critical tag and validates:
#   1. Database directories contain files
#   2. Key config files exist and are non-empty
#   3. App data has content
#
# The nightly backup (backup.sh) creates PER-STACK snapshots using ABSOLUTE
# host paths, so restores land under
#   ${RESTORE_DIR}/mnt/pool_HDD_x2/tank/datasources/sis/appdata/...
# This script locates that root dynamically instead of assuming a layout.
#
# Runs inside backup-cron-trigger container.
# Exit code 0 = all checks passed, 1 = one or more checks failed.

set -euo pipefail

RESTORE_DIR="/tmp/restore-test-$$"
APPDATA_REL="mnt/pool_HDD_x2/tank/datasources/sis/appdata"
NTFY_TOPIC="${NTFY_TOPIC:-}"
RESULTS=""
PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); RESULTS="${RESULTS}[PASS] $1\n"; }
fail() { FAIL=$((FAIL+1)); RESULTS="${RESULTS}[FAIL] $1\n"; }
skip() { RESULTS="${RESULTS}[SKIP] $1\n"; }

cleanup() {
    echo "[$(date -Iseconds)] Cleaning up restore directory..."
    docker exec backup-restic sh -c "rm -rf ${RESTORE_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "[$(date -Iseconds)] Starting monthly backup restore test..."

# Step 1: Restore the latest snapshot per critical tag.
# Nightly backups are split per-stack, so there is no single "latest".
for tag in operations iam vaultwarden monitoring db-dumps; do
    echo "[$(date -Iseconds)] Restoring tag: ${tag}..."
    if ! docker exec backup-restic sh -c "
        restic restore --tag ${tag} latest --target ${RESTORE_DIR} >/dev/null
    "; then
        fail "Restore failed for tag: ${tag}"
    fi
done

# Step 2: Locate the restored appdata root (dynamic - snapshot paths are absolute)
APPDATA="${RESTORE_DIR}/${APPDATA_REL}"
if ! docker exec backup-restic test -d "${APPDATA}"; then
    echo "Restore test FAILED: appdata root not found at ${APPDATA}"
    exit 1
fi
pass "Appdata root located"

# Step 3: Validate database directories (stacks whose tags we restored)
for db_entry in \
    "operations/postgres-forgejo:forgejo" \
    "iam/postgres:keycloak" \
    "vaultwarden:vaultwarden-sqlite"; do
    db_dir="${APPDATA}/${db_entry%%:*}"
    db_name="${db_entry##*:}"
    if docker exec backup-restic sh -c "test -d '${db_dir}'"; then
        file_count=$(docker exec backup-restic sh -c "find '${db_dir}' -type f 2>/dev/null | wc -l")
        if [ "${file_count}" -gt 0 ]; then
            pass "Database ${db_name}: ${file_count} files"
        else
            fail "Database ${db_name}: directory EMPTY"
        fi
    else
        fail "Database directory missing: ${db_name} at ${db_dir}"
    fi
done

# Step 4: Validate DB dump files (from db-dumps tag; dumps land under
# mnt/.../sis/backups/db-dumps-<date>/)
latest_dumps=$(docker exec backup-restic sh -c \
    "ls -d ${RESTORE_DIR}/mnt/pool_HDD_x2/tank/datasources/sis/backups/db-dumps-* 2>/dev/null | sort | tail -1")
if [ -n "${latest_dumps}" ]; then
    dump_count=$(docker exec backup-restic sh -c "find '${latest_dumps}' -name '*.dump' -o -name '*.sql' 2>/dev/null | wc -l")
    if [ "${dump_count}" -gt 0 ]; then
        pass "DB dumps: ${dump_count} dump files present"
    else
        fail "DB dumps dir exists but no dump files"
    fi
else
    fail "DB dumps not found in db-dumps snapshot"
fi

# Step 5: Validate key config files exist and are non-empty
for config_file in \
    "${APPDATA}/monitoring/victoriametrics/scrape.yml" \
    "${APPDATA}/monitoring/alertmanager/alertmanager.yml"; do
    if docker exec backup-restic sh -c "test -s '${config_file}'"; then
        size=$(docker exec backup-restic sh -c "wc -c < '${config_file}'")
        pass "Config $(basename "${config_file}"): ${size} bytes"
    else
        fail "Config missing or empty: ${config_file}"
    fi
done

# Step 6: Validate Forgejo data has content
forgejo_dir="${APPDATA}/operations/forgejo"
if docker exec backup-restic sh -c "test -d '${forgejo_dir}'"; then
    forgejo_files=$(docker exec backup-restic sh -c "find '${forgejo_dir}' -type f 2>/dev/null | wc -l")
    if [ "${forgejo_files}" -gt 0 ]; then
        pass "Forgejo data: ${forgejo_files} files"
    else
        fail "Forgejo data: EMPTY"
    fi
else
    fail "Forgejo data directory missing"
fi

# Step 7: Validate Vaultwarden database
vw_db="${APPDATA}/vaultwarden/db.sqlite3"
if docker exec backup-restic sh -c "test -s '${vw_db}'"; then
    size=$(docker exec backup-restic sh -c "wc -c < '${vw_db}'")
    pass "Vaultwarden SQLite: ${size} bytes"
else
    # some deployments keep it in a subdir
    if docker exec backup-restic sh -c "find '${APPDATA}/vaultwarden' -name 'db.sqlite3' 2>/dev/null | grep -q ."; then
        pass "Vaultwarden SQLite: found (nested path)"
    else
        fail "Vaultwarden db.sqlite3 missing"
    fi
fi

# Report results
echo ""
echo "=========================================="
echo "  MONTHLY BACKUP RESTORE TEST RESULTS"
echo "=========================================="
echo "  Passed:   ${PASS}"
echo "  Failed:   ${FAIL}"
echo "------------------------------------------"
printf "%b" "${RESULTS}"
echo "=========================================="

# Send ntfy notification
if [ -n "${NTFY_TOPIC}" ]; then
    if [ "${FAIL}" -eq 0 ]; then
        curl -s -H "Title: Backup Restore Test PASSED" \
             -H "Priority: default" \
             -d "All ${PASS} checks passed." \
             "https://ntfy.sh/${NTFY_TOPIC}" > /dev/null 2>&1 || true
    else
        curl -s -H "Title: Backup Restore Test FAILED" \
             -H "Priority: high" \
             -d "${FAIL} failed / ${PASS} passed." \
             "https://ntfy.sh/${NTFY_TOPIC}" > /dev/null 2>&1 || true
    fi
fi

if [ "${FAIL}" -gt 0 ]; then
    echo "[$(date -Iseconds)] Restore test FAILED"
    exit 1
fi
echo "[$(date -Iseconds)] Restore test PASSED"
exit 0
