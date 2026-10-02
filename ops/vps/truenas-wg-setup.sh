#!/bin/bash
# ============================================================================
# SIS TrueNAS WireGuard client — connects to VPS relay
# Run on TrueNAS as root AFTER the VPS is provisioned
# Requires: /root/wg-client-keys.txt copied from the VPS
# ============================================================================
set -euo pipefail

if [ ! -f /root/wg-client-keys.txt ]; then
  echo "ERROR: /root/wg-client-keys.txt not found - copy it from the VPS first"
  exit 1
fi

echo "=== 1. Install WireGuard ==="
# TrueNAS SCALE has wireguard-tools in the base
apt-get update -qq 2>/dev/null || true
which wg >/dev/null 2>&1 || { echo "installing wireguard-tools"; apt-get install -y -qq wireguard-tools 2>/dev/null || true; }

echo "=== 2. Extract client config from VPS keys file ==="
# Parse the [Interface] section from wg-client-keys.txt
WG_PRIV=$(grep 'PrivateKey' /root/wg-client-keys.txt | awk '{print $3}')
WG_PUB=$(grep 'PublicKey' /root/wg-client-keys.txt | awk '{print $3}')
WG_ENDPOINT=$(grep 'Endpoint' /root/wg-client-keys.txt | awk '{print $3}')

echo "=== 3. Write WireGuard client config ==="
mkdir -p /etc/wireguard
cat > /etc/wireguard/wg-sis.conf << WGCONF
[Interface]
Address = 10.99.0.2/24
PrivateKey = ${WG_PRIV}

[Peer]
# VPS relay
PublicKey = ${WG_PUB}
Endpoint = ${WG_ENDPOINT}
AllowedIPs = 10.99.0.1/32
PersistentKeepalive = 25
WGCONF
chmod 600 /etc/wireguard/wg-sis.conf

echo "=== 4. Start tunnel ==="
# TrueNAS uses the wireguard-go userspace implementation
wg-quick up /etc/wireguard/wg-sis.conf 2>/dev/null || \
  ip link add wg-sis type wireguard && \
  wg setconf wg-sis /etc/wireguard/wg-sis.conf && \
  ip addr add 10.99.0.2/24 dev wg-sis 2>/dev/null || true && \
  ip link set wg-sis up 2>/dev/null || true

echo "=== 5. Verify ==="
ping -c 2 -W 3 10.99.0.1 && echo "WireGuard tunnel: UP"
wg show wg-sis 2>/dev/null || wg show 2>/dev/null | head -6

echo ""
echo "=== DONE. TrueNAS reachable via VPS at 10.99.0.2 ==="
echo "Next: repoint DNS headscale.wyattau.com -> VPS public IP"
