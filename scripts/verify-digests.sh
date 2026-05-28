#!/usr/bin/env bash
# verify-digests.sh - Verify running container images against pinned digests
#
# Usage: ./scripts/verify-digests.sh [--ci]
#   --ci  Output GitHub Actions format (for use in CI)
#
# Reads versions.digests and compares against docker inspect output.
# Exit 1 if any container doesn't match its pinned digest.
#
# EIR custom builds (ghcr.io/wyattau/*) are skipped since they are
# rebuilt on-demand and their digests change.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIGEST_FILE="${SCRIPT_DIR}/../versions.digests"
CI_MODE=false

for arg in "$@"; do
  case "$arg" in
    --ci) CI_MODE=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

if [ ! -f "$DIGEST_FILE" ]; then
  echo "ERROR: Digest file not found: $DIGEST_FILE"
  exit 1
fi

# Build lookup: container image -> expected digest
declare -A EXPECTED_DIGESTS
while IFS='=' read -r key value; do
  # Skip comments and empty lines
  [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
  # Extract digest suffix (after @sha256:)
  if [[ "$value" =~ @sha256:([a-f0-9]+) ]]; then
    EXPECTED_DIGESTS["$key"]="${BASH_REMATCH[1]}"
  fi
done < "$DIGEST_FILE"

# Map from image names to digest variable names
# e.g. "postgres" -> "POSTGRES_DIGEST"
declare -A IMAGE_TO_DIGEST_VAR=(
  ["postgres"]="POSTGRES_DIGEST"
  ["mariadb"]="MARIADB_DIGEST"
  ["redis"]="REDIS_DIGEST"
  ["busybox"]="BUSYBOX_DIGEST"
  ["nginx"]="NGINX_DIGEST"
  ["restic"]="RESTIC_DIGEST"
  ["lscr.io/linuxserver/calibre-web"]="CALIBRE_WEB_DIGEST"
  ["matrixdotorg/synapse"]="SYNAPSE_DIGEST"
  ["vectorim/element-web"]="ELEMENT_DIGEST"
  ["ghcr.io/paperless-ngx/paperless-ngx"]="PAPERLESS_DIGEST"
  ["quay.io/keycloak/keycloak"]="KEYCLOAK_DIGEST"
  ["prom/alertmanager"]="ALERTMANAGER_DIGEST"
  ["prom/blackbox_exporter"]="BLACKBOX_EXPORTER_DIGEST"
  ["gcr.io/cadvisor/cadvisor"]="CADVISOR_DIGEST"
  ["google/cadvisor"]="CADVISOR_DIGEST"
  ["grafana/grafana"]="GRAFANA_DIGEST"
  ["grafana/promtail"]="PROMTAIL_DIGEST"
  ["prom/node-exporter"]="NODE_EXPORTER_DIGEST"
  ["prometheuscommunity/postgres-exporter"]="POSTGRES_EXPORTER_DIGEST"
  ["oliver006/redis_exporter"]="REDIS_EXPORTER_DIGEST"
  ["grafana/tempo"]="TEMPO_DIGEST"
  ["louislam/uptime-kuma"]="KUMA_DIGEST"
  ["victoriametrics/victoriametrics-logs"]="VICTORIALOGS_DIGEST"
  ["victoriametrics/victoria-logs"]="VICTORIALOGS_DIGEST"
  ["victoriametrics/victoriametrics"]="VICTORIAMETRICS_DIGEST"
  ["victoriametrics/victoria-metrics"]="VICTORIAMETRICS_DIGEST"
  ["victoriametrics/vmalert"]="VMALERT_DIGEST"
  ["ghcr.io/immich-app/immich-server"]="IMMICH_DIGEST"
  ["ghcr.io/immich-app/immich"]="IMMICH_DIGEST"
  ["ghcr.io/immich-app/immich-machine-learning"]="IMMICH_ML_DIGEST"
  ["ghcr.io/immich-app/postgres"]="IMMICH_POSTGRES_DIGEST"
  ["eqalpha/keydb"]="VALKEY_DIGEST"
  ["valkey/valkey"]="VALKEY_DIGEST"
  ["valkey"]="VALKEY_DIGEST"
  ["rabbitmq"]="RABBITMQ_DIGEST"
  ["ghcr.io/taigaio/taiga-back"]="TAIGA_BACK_DIGEST"
  ["taigaio/taiga-back"]="TAIGA_BACK_DIGEST"
  ["ghcr.io/taigaio/taiga-events"]="TAIGA_EVENTS_DIGEST"
  ["taigaio/taiga-events"]="TAIGA_EVENTS_DIGEST"
  ["ghcr.io/taigaio/taiga-front"]="TAIGA_FRONT_DIGEST"
  ["taigaio/taiga-front"]="TAIGA_FRONT_DIGEST"
  ["ghcr.io/taigaio/taiga-protected"]="TAIGA_PROTECTED_DIGEST"
  ["taigaio/taiga-protected"]="TAIGA_PROTECTED_DIGEST"
  ["bitnami/oauth2-proxy"]="OAUTH2_PROXY_DIGEST"
  ["quay.io/oauth2-proxy/oauth2-proxy"]="OAUTH2_PROXY_DIGEST"
  ["tecnativa/docker-socket-proxy"]="SOCKET_PROXY_DIGEST"
  ["freshrss/freshrss"]="FRESHRSS_DIGEST"
  ["crowdsecurity/crowdsec"]="CROWDSEC_DIGEST"
  ["alpine"]="ALPINE_DIGEST"
  ["collabora/code"]="COLLABORA_DIGEST"
  ["owncloud/ocis"]="OCIS_DIGEST"
  ["containrrr/watchtower"]="WATCHTOWER_DIGEST"
  ["gethomepage/homepage"]="HOMEPAGE_DIGEST"
  ["vaultwarden/server"]="VAULTWARDEN_DIGEST"
  ["linuxserver/wireguard"]="WIREGUARD_DIGEST"
  ["prom/mysqld-exporter"]="MYSQLD_EXPORTER_DIGEST"
  ["akaunting/akaunting"]="AKAUNTING_DIGEST"
  ["ghcr.io/zfs-exporter/zfs-exporter"]="ZFS_EXPORTER_DIGEST"
  ["restic/restic"]="RESTIC_DIGEST"
  ["postgis/postgis"]="POSTGRES_DIGEST"
)

FAILED=0
CHECKED=0
SKIPPED=0

# Collect running containers into a temp file (avoids process substitution issues)
CONTAINER_LIST=$(mktemp)
trap 'rm -f "$CONTAINER_LIST"' EXIT
sudo docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null | sort -u -k2 > "$CONTAINER_LIST"

while IFS=' ' read -r image_id image_name; do
  # Skip EIR custom builds
  if [[ "$image_name" == ghcr.io/wyattau/* ]]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Find the digest variable for this image
  base_image="${image_name%%:*}"  # Strip tag
  digest_var="${IMAGE_TO_DIGEST_VAR[$base_image]:-}"

  if [ -z "$digest_var" ]; then
    if $CI_MODE; then
      echo "::warning::No digest pin for image: $image_name"
    else
      echo "[WARN] No digest pin for: $image_name"
    fi
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  expected="${EXPECTED_DIGESTS[$digest_var]:-}"
  if [ -z "$expected" ]; then
    if $CI_MODE; then
      echo "::warning::Digest variable $digest_var not found in versions.digests"
    else
      echo "[WARN] Digest var $digest_var not found in versions.digests"
    fi
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Get the actual digest from docker image inspect (not container inspect)
  actual=$(sudo docker image inspect --format '{{index .RepoDigests 0}}' "$image_name" 2>/dev/null | sed 's/.*sha256://' || true)

  if [ -z "$actual" ]; then
    if $CI_MODE; then
      echo "::error::Could not inspect image: $image_name"
    else
      echo "[FAIL] Could not inspect: $image_name"
    fi
    FAILED=$((FAILED + 1))
    continue
  fi

  CHECKED=$((CHECKED + 1))

  if [ "$actual" = "$expected" ]; then
    if $CI_MODE; then
      echo "[PASS] $image_name"
    else
      echo "[PASS] $image_name (sha256:${actual:0:16}...)"
    fi
  else
    if $CI_MODE; then
      echo "::error::Digest mismatch for $image_name: expected ${expected:0:16}... got ${actual:0:16}..."
    else
      echo "[FAIL] $image_name: expected ${expected:0:16}... got ${actual:0:16}..."
    fi
    FAILED=$((FAILED + 1))
  fi
done < "$CONTAINER_LIST"

echo ""
echo "=== Digest Verification Summary ==="
echo "Checked: $CHECKED"
echo "Passed:  $((CHECKED - FAILED))"
echo "Failed:  $FAILED"
echo "Skipped: $SKIPPED (EIR builds + unpinned)"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
