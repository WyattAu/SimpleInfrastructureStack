#!/bin/bash
# prepull-base-images.sh
# Pre-pull Docker base images used in CI builds to avoid slow
# pulls during CI job execution on TrueNAS's limited bandwidth.
# Runs daily via cron.
#
# Images pulled:
#   - peptide-web: Bun + Node Alpine base
#   - QuestHive: Rust via nix (images pulled by nix, not docker)
#   - General CI: act runner base (catthehacker/ubuntu)

set -euo pipefail

LOG_FILE="/mnt/pool_HDD_x2/infra/logs/prepull-images.log"
exec >> "$LOG_FILE" 2>&1
date "+[%Y-%m-%d %H:%M:%S] Starting base image pre-pull"

IMAGES=(
  "oven/bun:1.3.11-alpine"
  "node:22-alpine"
  "postgres:16-alpine"
  "redis:7-alpine"
  "catthehacker/ubuntu:act-latest"
  "postgres:16"
  "archlinux:latest"
)

for img in "${IMAGES[@]}"; do
  echo -n "  $img ... "
  if docker pull "$img" >/dev/null 2>&1; then
    echo "OK"
  else
    echo "FAILED (non-fatal)"
  fi
done

date "+[%Y-%m-%d %H:%M:%S] Pre-pull complete"
