#!/bin/bash
# Repoint headscale.wyattau.com from direct A to VPS public IP
# Usage: ./dns-to-vps.sh <VPS_PUBLIC_IP>
set -euo pipefail
VPS_IP="${1:?Usage: dns-to-vps.sh <VPS_PUBLIC_IP>}"
CF="Authorization: Bearer ${CF_API_TOKEN:?Set CF_API_TOKEN env var}"
ZONE=55ec52794cd169def38cb5ca2cad3481

# Delete existing records for headscale.wyattau.com
for ID in $(curl -s -H "$CF" "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?name=headscale.wyattau.com" | python3 -c "import sys,json; [print(r['id']) for r in json.load(sys.stdin)['result']]"); do
  curl -s -X DELETE -H "$CF" "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records/$ID" > /dev/null
  echo "deleted $ID"
done

# Create A record pointing at VPS
curl -s -X POST -H "$CF" -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
  -d "{\"type\":\"A\",\"name\":\"headscale\",\"content\":\"$VPS_IP\",\"proxied\":false,\"ttl\":300,\"comment\":\"headscale via VPS relay\"}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('A record:', d['success'], d.get('result',{}).get('content',''))"
echo "DNS repointed to VPS. josh + msi-ge66 will reconnect within 30s."
