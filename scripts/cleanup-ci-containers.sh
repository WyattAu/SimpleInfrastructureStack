#!/bin/bash
# cleanup-ci-containers.sh
# Clean up Forgejo Actions CI containers.
# Prevents memory exhaustion from accumulated task containers.
# Runs via cron every 30 minutes.
#
# Actions:
# 1. Stop CI containers running longer than MAX_RUNTIME (default: 2 hours)
# 2. Remove exited/dead CI containers
# 3. Report stats

set -euo pipefail

MAX_RUNTIME="${MAX_RUNTIME:-7200}"  # 2 hours in seconds
LOG_TAG="cleanup-ci"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${LOG_TAG}] $*"; }

# --- Stop long-running CI containers ---
# Some tasks fail but leave containers running indefinitely.
# This catches orphaned containers the runner didn't clean up.
stopped=0
while IFS= read -r cid; do
  name="$(docker inspect --format '{{.Name}}' "$cid" | tr -d '/')"
  log "Stopping long-running container: ${name} (exceeded ${MAX_RUNTIME}s)"
  docker stop "$cid" >/dev/null 2>&1 || true
  docker rm "$cid" >/dev/null 2>&1 || true
  stopped=$((stopped + 1))
done < <(docker ps --filter "name=FORGEJO-ACTIONS" --filter "status=running" \
  --format '{{.ID}} {{.Status}}' | \
  awk -v max="${MAX_RUNTIME}" '
    /Up [0-9]+/ {
      split($2, t, ":")
      if (t[2] == "hour" || t[2] == "hours") {
        hours = int($1)
        if (hours * 3600 > max) print $0
      } else if (t[2] ~ /^[0-9]+$/) {
        # Up N (days)
        days = int($1)
        if (days * 86400 > max) print $0
      }
    }
    /^$/ { next }
  ')

if [ "$stopped" -gt 0 ]; then
  log "Stopped ${stopped} long-running CI containers"
fi

# --- Remove exited CI containers ---
exited=$(docker ps -a --filter "name=FORGEJO-ACTIONS" --filter "status=exited" -q | wc -l)
if [ "$exited" -gt 0 ]; then
  docker ps -a --filter "name=FORGEJO-ACTIONS" --filter "status=exited" -q | \
    xargs -r docker rm >/dev/null 2>&1 || true
  log "Removed ${exited} exited CI containers"
fi

# --- Remove dead containers ---
dead=$(docker ps -a --filter "status=dead" -q | wc -l)
if [ "$dead" -gt 0 ]; then
  docker ps -a --filter "status=dead" -q | \
    xargs -r docker rm >/dev/null 2>&1 || true
  log "Removed ${dead} dead containers"
fi

# --- Summary ---
total=$(docker ps -a --filter "name=FORGEJO-ACTIONS" -q | wc -l)
running=$(docker ps --filter "name=FORGEJO-ACTIONS" -q | wc -l)
log "CI container cleanup complete: ${running} running, ${total} total remaining"
