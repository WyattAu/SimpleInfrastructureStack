#!/bin/bash
# ===================================================================
# Auto-Restart Script for SimpleInfrastructureStack
# ===================================================================
# Designed to be triggered by Uptime Kuma webhook on service failure.
# Restarts the unhealthy container via Docker API.
# ===================================================================

set -euo pipefail

# Configuration
DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
LOG_PREFIX="[auto-restart]"

# Parse arguments
CONTAINER_NAME="${1:?Usage: $0 <container-name>}"

echo "$LOG_PREFIX $(date -Iseconds) Restart triggered for: $CONTAINER_NAME"

# Check if container exists
if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "$LOG_PREFIX ERROR: Container '$CONTAINER_NAME' not found"
  exit 1
fi

# Get container state
CONTAINER_STATUS=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")
echo "$LOG_PREFIX Current status: $CONTAINER_STATUS"

# Restart the container
echo "$LOG_PREFIX Restarting $CONTAINER_NAME..."
docker restart "$CONTAINER_NAME"

# Wait for health check
echo "$LOG_PREFIX Waiting for health check..."
MAX_WAIT=120
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
  HEALTH=$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
  if [ "$HEALTH" = "healthy" ]; then
    echo "$LOG_PREFIX $CONTAINER_NAME is healthy after ${WAITED}s"
    exit 0
  fi
  sleep 5
  WAITED=$((WAITED + 5))
done

echo "$LOG_PREFIX WARNING: $CONTAINER_NAME not healthy after ${MAX_WAIT}s"
exit 1
