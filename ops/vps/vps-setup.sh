#!/bin/bash
# ============================================================================
# SIS VPS Relay Setup — run on the Oracle Cloud VPS as root
# Sets up: WireGuard server + TCP 443 proxy to TrueNAS via tunnel
# ============================================================================
set -euo pipefail

echo "=== 1. System packages ==="
apt-get update -qq
apt-get install -y -qq wireguard wireguard-tools socat nginx ufw

echo "=== 2. WireGuard server config ==="
# Generate keys (server + one client slot for TrueNAS)
mkdir -p /etc/wireguard
WG_SERVER_PRIV=$(wg genkey)
WG_SERVER_PUB=$(echo "$WG_SERVER_PRIV" | wg pubkey)
WG_CLIENT_PRIV=$(wg genkey)
WG_CLIENT_PUB=$(echo "$WG_CLIENT_PRIV" | wg pubkey)

cat > /etc/wireguard/wg0.conf << WGCONF
[Interface]
Address = 10.99.0.1/24
ListenPort = 51820
PrivateKey = ${WG_SERVER_PRIV}

[Peer]
# TrueNAS (behind CGNAT - outbound only)
PublicKey = ${WG_CLIENT_PUB}
AllowedIPs = 10.99.0.2/32
WGCONF

chmod 600 /etc/wireguard/wg0.conf

# Save keys for the client config
cat > /root/wg-client-keys.txt << KEYEOF
# TrueNAS WireGuard client config
[Interface]
Address = 10.99.0.2/24
PrivateKey = ${WG_CLIENT_PRIV}

[Peer]
# VPS relay
PublicKey = ${WG_SERVER_PUB}
Endpoint = <VPS_PUBLIC_IP>:51820
AllowedIPs = 10.99.0.1/32
PersistentKeepalive = 25
KEYEOF
chmod 600 /root/wg-client-keys.txt

echo "=== 3. Enable IP forwarding ==="
sysctl -w net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

echo "=== 4. WireGuard up ==="
systemctl enable --now wg-quick@wg0

echo "=== 5. Firewall (ufw) ==="
ufw allow 22/tcp    # SSH
ufw allow 443/tcp   # HTTPS proxy
ufw allow 51820/udp # WireGuard
ufw --force enable

echo "=== 6. TCP 443 proxy -> TrueNAS via WireGuard ==="
# socat: listen 443 on all interfaces, forward to TrueNAS WG IP 443
cat > /etc/systemd/system/sis-relay-443.service << UNIT
[Unit]
Description=SIS relay: TCP 443 -> TrueNAS via WireGuard
After=network.target wg-quick@wg0.service

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:443,fork,reuseaddr PROXY:10.99.0.2:127.0.0.1:443,proxyport=1080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
# simpler: use socat direct TCP forward (no SOCKS proxy needed since WG is routed)
cat > /etc/systemd/system/sis-relay-443.service << UNIT
[Unit]
Description=SIS relay: TCP 443 -> TrueNAS via WireGuard
After=network.target wg-quick@wg0.service

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:443,fork,reuseaddr TCP:10.99.0.2:443
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now sis-relay-443.service

echo "=== 7. Keep alive ==="
systemctl enable wg-quick@wg0

echo ""
echo "=========================================="
echo "VPS SETUP COMPLETE"
echo "=========================================="
echo "VPS public IP: $(curl -s --max-time 10 https://api.ipify.org)"
echo "WG server pub key: ${WG_SERVER_PUB}"
echo ""
echo "NEXT: copy /root/wg-client-keys.txt to TrueNAS and configure wg0 there."
echo "Then: DNS headscale.wyattau.com -> $(curl -s --max-time 10 https://api.ipify.org)"
