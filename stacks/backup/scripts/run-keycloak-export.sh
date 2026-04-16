#!/bin/sh
# Keycloak Realm Export Script
# Exports the company-realm configuration (users, clients, roles) to a JSON file
# in the backup data directory so it gets included in the nightly Restic backup.
#
# Runs inside backup-cron-trigger container.
# Uses Keycloak's admin API with kcadm.sh (available inside the Keycloak container).
#
# The export file is written to ${DATA_BASE_PATH}/iam/realm-export/ which is
# a subdirectory of the backup source mount.

set -euo pipefail

KC_CONTAINER="iam-keycloak"
REALM="company-realm"
EXPORT_DIR="/data/iam/realm-export"
EXPORT_FILE="${EXPORT_DIR}/company-realm-export.json"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

echo "[$(date -Iseconds)] Starting Keycloak realm export..."

# Ensure export directory exists
docker exec "${KC_CONTAINER}" mkdir -p /opt/keycloak/data/export 2>/dev/null || true

# Export realm using kcadm.sh (runs inside the Keycloak container).
# --users realm_file exports users with credentials hashed.
# --groups, --clients, --roles export all identity artifacts.
docker exec "${KC_CONTAINER}" /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password "${KEYCLOAK_ADMIN_PASSWORD:-}" \
  2>/dev/null

docker exec "${KC_CONTAINER}" /opt/keycloak/bin/kcadm.sh export \
  --realm "${REALM}" \
  --file /opt/keycloak/data/export/company-realm-export.json \
  --users realm_file \
  2>/dev/null

# Copy exported file from container to backup-accessible location
docker cp "${KC_CONTAINER}:/opt/keycloak/data/export/company-realm-export.json" "${EXPORT_FILE}.tmp" 2>/dev/null || {
  echo "[$(date -Iseconds)] WARNING: Keycloak export failed — container may not be ready"
  # Create a marker file so we know the export failed
  echo "{\"export_error\": \"kcadm export failed at ${TIMESTAMP}\", \"realm\": \"${REALM}\"}" > "${EXPORT_FILE}"
  exit 0
}

# Rotate: keep latest export and one previous
if [ -f "${EXPORT_FILE}" ]; then
  mv "${EXPORT_FILE}" "${EXPORT_FILE}.prev"
fi
mv "${EXPORT_FILE}.tmp" "${EXPORT_FILE}"

SIZE=$(wc -c < "${EXPORT_FILE}" 2>/dev/null || echo "0")
echo "[$(date -Iseconds)] Keycloak realm export completed (${SIZE} bytes)"
