#!/bin/bash
# Pre-render alertmanager.yml from template
# Run this before docker compose up

TEMPLATE="stacks/monitoring/alertmanager/alertmanager.yml.tmpl"
OUTPUT="stacks/monitoring/alertmanager/alertmanager.yml"

if [ -f "$TEMPLATE" ]; then
  sed \
    -e "s|\${NTFY_TOPIC}|${NTFY_TOPIC:-alerts}|g" \
    "$TEMPLATE" > "$OUTPUT"
  echo "Rendered $OUTPUT from $TEMPLATE"
else
  echo "Template not found: $TEMPLATE"
  exit 1
fi
