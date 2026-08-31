#!/bin/bash
# =============================================================================
# Secret Rotation Script for SIS Infrastructure
# =============================================================================
# Rotates secrets across all stacks. Run this periodically or after a breach.
#
# Usage: bash scripts/rotate-secrets.sh [--dry-run]
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
DRY_RUN=${1:-false}

echo "=== SIS Secret Rotation ==="
echo "Mode: $(if [ "$DRY_RUN" = "--dry-run" ]; then echo 'DRY RUN'; else echo 'LIVE'; fi)"
echo ""

# Generate a random 32-byte hex string
generate_secret() {
    openssl rand -hex 32
}

# Rotate a secret in a file
rotate_in_file() {
    local file="$1"
    local old="$2"
    local new="$3"
    local desc="$4"
    
    if [ ! -f "$file" ]; then
        echo "  SKIP: $file not found"
        return
    fi
    
    if grep -q "$old" "$file" 2>/dev/null; then
        if [ "$DRY_RUN" = "--dry-run" ]; then
            echo "  WOULD ROTATE: $desc in $file"
        else
            sed -i "s|$old|$new|g" "$file"
            echo "  ROTATED: $desc in $file"
        fi
    else
        echo "  SKIP: $desc not found in $file (already rotated?)"
    fi
}

# Generate secrets
NEW_SMTP_PASS=$(generate_secret)
NEW_FORGEJO_OIDC=$(generate_secret)
NEW_KEYCLOAK_SECRET=$(generate_secret)
NEW_ADMIN_TOKEN=$(generate_secret)
NEW_GRAFANA_OIDC=$(generate_secret)
NEW_COOKIE_SECRET=$(generate_secret)

echo "Generated new secrets (not shown for security)"
echo ""

# Rotate secrets across stacks
echo "=== Rotating SMTP password ==="
rotate_in_file "stacks/monitoring/.env" "SMTP_PASSWORD=.*" "SMTP_PASSWORD=$NEW_SMTP_PASS" "SMTP password"
rotate_in_file "stacks/monitoring/.env.example" "SMTP_PASSWORD=.*" "SMTP_PASSWORD=GENERATE_THIS" "SMTP password (example)"

echo "=== Rotating Keycloak OIDC secrets ==="
rotate_in_file "stacks/iam/.env" "FORGEJO_OIDC_CLIENT_SECRET=.*" "FORGEJO_OIDC_CLIENT_SECRET=$NEW_FORGEJO_OIDC" "Forgejo OIDC secret"
rotate_in_file "stacks/iam/.env" "GRAFANA_OIDC_CLIENT_SECRET=.*" "GRAFANA_OIDC_CLIENT_SECRET=$NEW_GRAFANA_OIDC" "Grafana OIDC secret"
rotate_in_file "stacks/iam/.env" "KEYCLOAK_ADMIN_PASSWORD=.*" "KEYCLOAK_ADMIN_PASSWORD=$NEW_KEYCLOAK_SECRET" "Keycloak admin password"

echo "=== Rotating Grafana OIDC secrets ==="
rotate_in_file "stacks/monitoring/.env" "GRAFANA_OIDC_CLIENT_SECRET=.*" "GRAFANA_OIDC_CLIENT_SECRET=$NEW_GRAFANA_OIDC" "Grafana OIDC secret"

echo "=== Rotating Vaultwarden admin token ==="
rotate_in_file "stacks/vaultwarden/.env" "ADMIN_TOKEN=.*" "ADMIN_TOKEN=$NEW_ADMIN_TOKEN" "Vaultwarden admin token"

echo "=== Rotating Cookie secrets ==="
rotate_in_file "stacks/proxy/.env" "OAUTH2_PROXY_COOKIE_SECRET=.*" "OAUTH2_PROXY_COOKIE_SECRET=$NEW_COOKIE_SECRET" "OAuth2 proxy cookie secret"

echo ""
echo "=== Summary ==="
echo "After rotation, restart affected services:"
echo "  cd /mnt/pool_HDD_x2/infra/stacks/stacks"
echo "  for stack in iam monitoring vaultwarden proxy; do"
echo "    cd \$stack && sudo docker compose up -d && cd .."
echo "  done"
echo ""
echo "IMPORTANT: Update the following external services with new credentials:"
echo "  - Keycloak: Update Forgejo OIDC client secret"
echo "  - Keycloak: Update Grafana OIDC client secret"
echo "  - SMTP: Update SMTP password in mail provider"
