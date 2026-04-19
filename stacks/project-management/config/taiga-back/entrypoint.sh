#!/usr/bin/env bash
# Custom entrypoint for taiga-back that skips the chown step.
# The upstream entrypoint runs 'chown -R taiga:taiga /taiga-back' which
# hangs on named Docker volumes (overlayfs traversal issue).
# Ownership is handled by the taiga-back-init container instead.
set -euo pipefail

# Execute pending migrations
echo Executing pending migrations
python manage.py migrate

# Load default templates
echo Load default templates
python manage.py loaddata initial_project_templates

# Skip chown — handled by taiga-back-init container
echo Skipping chown (handled by init container)

# Start Taiga processes
echo Starting Taiga API...
exec gosu taiga gunicorn taiga.wsgi:application \
    --name taiga_api \
    --bind 0.0.0.0:8000 \
    --workers 3 \
    --worker-tmp-dir /dev/shm \
    --log-level=info \
    --access-logfile - \
    "$@"
