#!/bin/bash
# ===================================================================
# PostgreSQL Backup Script
# ===================================================================
# Dumps all PostgreSQL databases to individual SQL files.
# Designed to run as a cron job or via backup-cron-trigger.
# ===================================================================

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/tmp/db-backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS="${RETENTION_DAYS:-7}"

# List of PostgreSQL containers
PG_CONTAINERS=(
  "iam-postgres"
  "operations-postgres-forgejo"
  "collaboration-postgres"
  "accounting-postgres-akaunting"
  "rss-postgres"
  "photos-postgres"
  "documents-postgres"
)

mkdir -p "$BACKUP_DIR"

echo "[$(date -Iseconds)] Starting PostgreSQL backups..."

for container in "${PG_CONTAINERS[@]}"; do
  if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
    echo "  Backing up $container..."

    # Get database info from container environment
    DB_NAME=$(docker exec "$container" printenv POSTGRES_DB 2>/dev/null || echo "unknown")
    DB_USER=$(docker exec "$container" printenv POSTGRES_USER 2>/dev/null || echo "postgres")

    # Create backup
    BACKUP_FILE="${BACKUP_DIR}/${container}_${DB_NAME}_${TIMESTAMP}.sql.gz"
    docker exec "$container" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$BACKUP_FILE"

    if [ -f "$BACKUP_FILE" ] && [ -s "$BACKUP_FILE" ]; then
      echo "    OK: $(du -h "$BACKUP_FILE" | cut -f1)"
    else
      echo "    FAILED: Backup file is empty or missing"
    fi
  else
    echo "  SKIP: $container is not running"
  fi
done

# Clean up old backups
echo "Cleaning up backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +${RETENTION_DAYS} -delete

echo "[$(date -Iseconds)] PostgreSQL backup completed."
