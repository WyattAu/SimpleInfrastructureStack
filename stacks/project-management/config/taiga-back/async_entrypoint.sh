#!/usr/bin/env bash
# Custom entrypoint for taiga-async that skips the chown step.
# The upstream entrypoint runs 'chown -R taiga:taiga /taiga-back' which
# hangs on named Docker volumes (overlayfs traversal issue).
# Ownership is handled by the taiga-back-init container instead.
set -euo pipefail

# Skip chown — handled by taiga-back-init container
echo Skipping chown (handled by init container)

# Start Celery processes
echo Starting Celery...
exec gosu taiga celery -A taiga.celery worker -B \
    --concurrency 4 \
    -l INFO \
    "$@"
