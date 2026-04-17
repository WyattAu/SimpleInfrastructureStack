#!/usr/bin/env bash
# ===================================================================
# Terraform helper script
# ===================================================================
# Loads SOPS secrets into TF_VAR_* environment variables and runs
# the specified Terraform command.
#
# Usage:
#   ./scripts/tf.sh init
#   ./scripts/tf.sh plan
#   ./scripts/tf.sh apply
#   ./scripts/tf.sh import cloudflare_dns_record.vpn <record_id>
#
# Prerequisites:
#   - sops installed and age key available
#   - terraform installed (or run inside infra-webhook container)
# ===================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TF_DIR="$REPO_DIR/terraform"

# Source SOPS secrets into environment variables
echo "Loading SOPS secrets..."

# Cloudflare
CF_API_TOKEN=$(sops -d --input-type dotenv --output-type dotenv \
  "$REPO_DIR/secrets/proxy.env.encrypted" 2>/dev/null \
  | grep '^CF_API_TOKEN=' | cut -d= -f2 | tr -d "'")
export TF_VAR_cf_api_token="$CF_API_TOKEN"

# Keycloak
KC_PASS=$(sops -d --input-type dotenv --output-type dotenv \
  "$REPO_DIR/secrets/iam.env.encrypted" 2>/dev/null \
  | grep '^KEYCLOAK_ADMIN_PASSWORD=' | cut -d= -f2 | tr -d "'")
export TF_VAR_kc_admin_password="$KC_PASS"

KC_SMTP_PASS=$(sops -d --input-type dotenv --output-type dotenv \
  "$REPO_DIR/secrets/iam.env.encrypted" 2>/dev/null \
  | grep '^SMTP_PASSWORD=' | cut -d= -f2 | tr -d "'")
export TF_VAR_kc_smtp_password="$KC_SMTP_PASS"

# Keycloak client secrets
export TF_VAR_kc_oauth2_proxy_secret=$(
  sops -d --input-type dotenv --output-type dotenv \
    "$REPO_DIR/secrets/proxy.env.encrypted" 2>/dev/null \
    | grep '^OAUTH2_PROXY_CLIENT_SECRET=' | cut -d= -f2 | tr -d "'")

export TF_VAR_kc_grafana_secret=$(
  sops -d --input-type dotenv --output-type dotenv \
    "$REPO_DIR/secrets/monitoring.env.encrypted" 2>/dev/null \
    | grep '^GRAFANA_OIDC_CLIENT_SECRET=' | cut -d= -f2 | tr -d "'")

# Forgejo token (generated via: gitea admin user generate-access-token)
# NOTE: If this fails, generate a new token:
#   ssh truenas_admin@192.168.1.3 \
#     "sudo docker exec -u git operations-forgejo gitea -c /data/gitea/conf/app.ini \
#      admin user generate-access-token -u wyatt_admin --scopes all -t terraform"
if [ -f "$REPO_DIR/.forgejo_token" ]; then
  export TF_VAR_forgejo_token=$(cat "$REPO_DIR/.forgejo_token")
else
  echo "WARNING: .forgejo_token not found. Forgejo resources will be skipped."
  echo "Generate one with: gitea admin user generate-access-token -u wyatt_admin --scopes all -t terraform"
  export TF_VAR_forgejo_token="placeholder"
fi

echo "Running: terraform $*"
cd "$TF_DIR"
terraform "$@"
