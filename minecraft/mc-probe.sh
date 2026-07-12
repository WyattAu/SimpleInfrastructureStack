#!/bin/bash
# MC server liveness check — runs on CachyOS via systemd timer
# Writes metrics to node-exporter textfile collector
set -euo pipefail

TEXTFILE_DIR="/home/wyatt/node-textfile"
mkdir -p "$TEXTFILE_DIR"

java_up=$(ss -tlnp 2>/dev/null | grep -c ':25565' || echo 0)
bedrock_up=$(ss -ulnp 2>/dev/null | grep -c ':19132' || echo 0)

# Get player count from server log (last "players" line)
players=0
if incus list mc-purpur --format csv -c s 2>/dev/null | grep -q RUNNING; then
    players=$(incus exec mc-purpur -- bash -c \
        "grep -oP '\d+(?=/20)' /opt/minecraft/logs/latest.log 2>/dev/null | tail -1" 2>/dev/null)
    # Ensure we got a valid number
    [[ "$players" =~ ^[0-9]+$ ]] || players=0
fi

{
echo "# HELP mc_java_port_up Java edition port (25565) is listening"
echo "# TYPE mc_java_port_up gauge"
echo "mc_java_port_up ${java_up}"

echo "# HELP mc_bedrock_port_up Bedrock edition port (19132) is listening"
echo "# TYPE mc_bedrock_port_up gauge"
echo "mc_bedrock_port_up ${bedrock_up}"

echo "# HELP mc_players_online Players currently online"
echo "# TYPE mc_players_online gauge"
echo "mc_players_online ${players}"

echo "# HELP mc_probe_timestamp Unix timestamp of last probe"
echo "# TYPE mc_probe_timestamp gauge"
echo "mc_probe_timestamp $(date +%s)"
} > "${TEXTFILE_DIR}/mc.prom"
