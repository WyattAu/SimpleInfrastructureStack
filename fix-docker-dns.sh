#!/bin/bash
set -e
echo "Checking CoreDNS namespace status..."
GOOD_NS=$(sudo docker inspect --format '{{.State.Pid}}' headscale-server 2>/dev/null)
# Find the DNS container (could be named dns or coredns)
DNS_CONTAINER=$(sudo docker ps -a --format '{{.Names}}' | grep -iE '^(dns|coredns)$' | head -1)
if [ -z "$DNS_CONTAINER" ]; then
    echo "No DNS container found. Skipping DNS fix."
    exit 0
fi
COREDNS_NS=$(sudo docker inspect --format '{{.State.Pid}}' "$DNS_CONTAINER" 2>/dev/null)
if [ -z "$GOOD_NS" ] || [ -z "$COREDNS_NS" ]; then
    echo "Cannot find container PIDs."
    exit 1
fi
GOOD_NET=$(nsenter -t $GOOD_NS -n ip route 2>/dev/null | head -1)
COREDNS_NET=$(nsenter -t $COREDNS_NS -n ip route 2>/dev/null | head -1)
if [ "$GOOD_NET" = "$COREDNS_NET" ]; then
    echo "CoreDNS is in the correct namespace. No fix needed."
    exit 0
fi
echo "CoreDNS namespace mismatch detected! Fixing..."
sudo systemctl reset-failed docker
sudo systemctl start docker
sleep 15
echo "Verifying..."
sudo docker ps --format 'table {{.Names}}\t{{.Status}}' | head -10
echo "Done."
