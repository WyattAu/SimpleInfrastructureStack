#!/bin/bash
# Deploy script for utility stack
# Handles the network_mode: bridge → traefik_net connect workaround
# Required because Docker embedded DNS is broken on TrueNAS user-defined networks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Start the stack
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d --force-recreate --pull never

# Wait for container to start
echo "Waiting for utility-homepage to start..."
sleep 5

# Connect to traefik_net for Traefik routing (silently skip if already connected)
if ! docker inspect utility-homepage --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null | grep -qw traefik_net; then
    echo "Connecting utility-homepage to traefik_net..."
    docker network connect traefik_net utility-homepage
    echo "Done."
else
    echo "utility-homepage already on traefik_net."
fi

# Verify DNS works
echo ""
echo "DNS verification:"
if docker exec utility-homepage nslookup api.github.com 2>/dev/null | grep -q "Address"; then
    echo "  ✓ DNS working"
else
    echo "  ✗ DNS FAILED"
fi

# Verify Traefik routing
echo "Traefik routing verification:"
if docker exec utility-homepage wget -q -O /dev/null --timeout=3 http://127.0.0.1:3000/ 2>/dev/null; then
    echo "  ✓ Homepage serving"
else
    echo "  ⚠ Homepage not yet ready (may still be starting)"
fi

echo ""
echo "Deploy complete."
