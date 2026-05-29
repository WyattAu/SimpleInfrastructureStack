#!/bin/bash
# restart-forgejo-weekly.sh
# Weekly Forgejo restart to flush stale concurrency/scheduler state.
# Runs Sunday 3 AM via cron.
#
# Forgejo accumulates stale run states (status=3 blocked) over time
# due to a known concurrency deadlock when multiple workflows from
# the same commit race. Restarting clears the in-memory scheduler cache.

set -euo pipefail

LOG_FILE="/mnt/pool_HDD_x2/infra/logs/forgejo-restart.log"
STACK_DIR="/mnt/pool_HDD_x2/infra/stacks/stacks/operations"

exec >> "$LOG_FILE" 2>&1
date "+[%Y-%m-%d %H:%M:%S] Starting scheduled Forgejo restart"

# 1. Cancel any stale blocked/pending/running CI runs in the DB
docker exec operations-postgres-forgejo psql -U forgejo -d forgejo -c \
  "UPDATE action_task SET status = 5 WHERE status IN (3, 4, 6);
   UPDATE action_run_job SET status = 5, task_id = 0 WHERE status IN (3, 4, 6);
   UPDATE action_run SET status = 5 WHERE status IN (3, 4, 6);" \
  2>/dev/null || true

# 2. Restart Forgejo
cd "$STACK_DIR"
docker compose restart forgejo
sleep 15

# 3. Wait for healthy
for i in $(seq 1 12); do
  if docker compose ps forgejo --format json 2>/dev/null | grep -q '"Health":"healthy"'; then
    date "+[%Y-%m-%d %H:%M:%S] Forgejo healthy after ${i}x5s"
    break
  fi
  sleep 5
done

# 4. Restart runners to reconnect
docker compose restart forgejo-runner runner-peptide-web runner-questhive
sleep 5

date "+[%Y-%m-%d %H:%M:%S] Forgejo restart complete"
