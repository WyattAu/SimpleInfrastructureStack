#!/bin/sh
set -e

# Substitute environment variables into hooks template
TEMPLATE="/opt/webhook/hooks.yaml.tmpl"
OUTPUT="/opt/webhook/hooks.yaml"

if [ -f "$TEMPLATE" ]; then
    # envsubst requires gettext; fall back to sed if unavailable
    if command -v envsubst >/dev/null 2>&1; then
        envsubst < "$TEMPLATE" > "$OUTPUT"
    else
        # Replace ${WEBHOOK_SECRET} with the env var value
        sed "s|\${WEBHOOK_SECRET}|${WEBHOOK_SECRET}|g" "$TEMPLATE" > "$OUTPUT"
    fi
    chmod 600 "$OUTPUT"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Generated hooks.yaml from template"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: No hooks.yaml.tmpl found, using hooks.yaml if present"
fi

exec webhook "$@"
