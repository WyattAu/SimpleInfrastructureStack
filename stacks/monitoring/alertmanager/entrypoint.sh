#!/bin/sh
# Alertmanager entrypoint wrapper.
# Renders alertmanager.yml template with environment variables using sed
# (envsubst is not available in the Chainguard-based alertmanager image),
# then execs the original Alertmanager entrypoint.
set -eu

TEMPLATE="/etc/alertmanager/alertmanager.yml.tpl"
OUTPUT="/etc/alertmanager/alertmanager.yml"

if [ -f "$TEMPLATE" ]; then
  sed \
    -e "s|\${NTFY_TOPIC}|${NTFY_TOPIC}|g" \
    "$TEMPLATE" > "$OUTPUT"
fi

exec alertmanager "$@"
