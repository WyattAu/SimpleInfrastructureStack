#!/bin/sh
# Alertmanager entrypoint wrapper.
# Renders alertmanager.yml template with environment variables via envsubst,
# then execs the original Alertmanager entrypoint.
set -eu

TEMPLATE="/etc/alertmanager/alertmanager.yml.tpl"
OUTPUT="/etc/alertmanager/alertmanager.yml"

if [ -f "$TEMPLATE" ]; then
  envsubst < "$TEMPLATE" > "$OUTPUT"
fi

exec alertmanager "$@"
