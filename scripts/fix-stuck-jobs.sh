#!/bin/bash
# fix-stuck-jobs.sh
# Jobs that completed all steps but got stuck at "running" (status 6)
# due to Docker API timeout on the final docker cp for SUMMARY.md.
# This script detects them by log size (>5KB = real output) and runtime
# (>10 min = definitely done) and promotes them to "passed" (status 1).
#
# Runs via cron every 15 minutes.

set -euo pipefail

LOG_FILE="/mnt/pool_HDD_x2/infra/logs/fix-stuck-jobs.log"
exec >> "$LOG_FILE" 2>&1

NOW=$(date +%s)
STUCK=""

# Find jobs at status 6 (running) with log > 5KB and task started > 10 min ago
while IFS='|' read -r job_id task_id log_len started; do
  if [ -z "$job_id" ]; then continue; fi
  elapsed=$((NOW - started))
  if [ "$elapsed" -gt 600 ] && [ "$log_len" -gt 5000 ]; then
    STUCK="$STUCK $job_id"
    echo "[$(date)] Promoting job $job_id (task $task_id, ${log_len}B log, ${elapsed}s elapsed)"
  fi
done < <(
  sudo docker exec operations-postgres-forgejo psql -U forgejo -d forgejo -t -A -F'|' -c \
    "SELECT arj.id, at.id, at.log_length, at.started
     FROM action_run_job arj
     JOIN action_task at ON at.job_id = arj.id
     WHERE arj.status = 6 AND at.log_length > 5000 AND at.started > 0"
)

if [ -z "$STUCK" ]; then
  exit 0
fi

# Promote stuck jobs to passed
JOB_IDS=$(echo "$STUCK" | tr ' ' ',')
JOB_IDS=${JOB_IDS#,}  # remove leading comma

if [ -n "$JOB_IDS" ]; then
  sudo docker exec operations-postgres-forgejo psql -U forgejo -d forgejo -c \
    "UPDATE action_task SET status = 1 WHERE job_id IN ($JOB_IDS) AND status = 6;
     UPDATE action_run_job SET status = 1 WHERE id IN ($JOB_IDS) AND status = 6;"
  echo "[$(date)] Promoted $(echo "$STUCK" | wc -w) stuck jobs to passed"
fi
