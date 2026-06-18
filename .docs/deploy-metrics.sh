#!/bin/bash
# deploy-metrics.sh — Export deploy metrics for VictoriaMetrics
# Called after each deploy to record success/failure and duration
#
# Usage: deploy-metrics.sh <status> <duration_seconds>
# Example: deploy-metrics.sh success 300

STATUS="${1:-unknown}"
DURATION="${2:-0}"
TIMESTAMP=$(date +%s)
DEPLOY_DIR="/mnt/pool_HDD_x2/tank/datasources/sis/backups"
METRICS_FILE="${DEPLOY_DIR}/deploy.prom"

cat > "$METRICS_FILE" << EOF
# HELP infra_deploy_last_timestamp_seconds Timestamp of last deploy
# TYPE infra_deploy_last_timestamp_seconds gauge
infra_deploy_last_timestamp_seconds $TIMESTAMP

# HELP infra_deploy_status Deploy status (1=success, 0=failure)
# TYPE infra_deploy_status gauge
infra_deploy_status $([ "$STATUS" = "success" ] && echo 1 || echo 0)

# HELP infra_deploy_duration_seconds Deploy duration in seconds
# TYPE infra_deploy_duration_seconds gauge
infra_deploy_duration_seconds $DURATION

# HELP infra_deploy_total Total number of deploys
# TYPE infra_deploy_total counter
infra_deploy_total 1
EOF

echo "Deploy metrics written: status=$STATUS duration=${DURATION}s"
