#!/bin/bash
# SIS meta-watchdog v5 - CachyOS-resident, independent of TrueNAS monitoring stack.
NTFY="https://ntfy.sh/wyattau-infra-0e92568ce5d04343c3b796ed558a04b9"
failures=""

# --- remote check bundle via script file (avoids nested-quoting failures) ---
cat > /tmp/sis-remote-check.sh << 'REMOTE'
PROM=/mnt/pool_HDD_x2/tank/datasources/sis/appdata/monitoring/textfile-collector/backup.prom
NOW=$(date +%s)
AGE=$(grep -E "^sis_backup_offsite_last_success " "$PROM" 2>/dev/null | head -1 | awk '{print $2}')
[ -z "$AGE" ] && AGE=0
echo "OFFSITE_AGE=$(( NOW - AGE ))"
BAD=$(sudo docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -cE 'unhealthy|Restarting')
EXPECT=$(sudo docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -E 'unhealthy|Restarting' | grep -cE 'promtail|cadvisor|node-exporter')
BAD=$(( BAD - EXPECT ))
[ "$BAD" -lt 0 ] && BAD=0
echo "FLEET_BAD=$BAD"
curl -s --max-time 8 http://192.168.1.3:8080/health 2>/dev/null | grep -q pass && echo "HEADSCALE=ok" || echo "HEADSCALE=down"
SD=$(curl -sG --max-time 8 "http://172.16.7.200:8428/api/v1/query" --data-urlencode 'query=count(up == 0)' | python3 -c 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)' 2>/dev/null)
echo "SCRAPE_DOWN=${SD:-unknown}"
REMOTE
scp -q /tmp/sis-remote-check.sh truenas_admin@192.168.1.3:/tmp/sis-remote-check.sh >/dev/null 2>&1
REMOTE_REPORT=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new truenas_admin@192.168.1.3 'bash /tmp/sis-remote-check.sh' 2>/dev/null)
ssh -o ConnectTimeout=10 truenas_admin@192.168.1.3 'rm -f /tmp/sis-remote-check.sh' >/dev/null 2>&1

eval "$REMOTE_REPORT"

[ "${OFFSITE_AGE:-0}" -gt 90000 ] && failures="$failures\n- OFFSITE BACKUP STALE: ${OFFSITE_AGE}h since last success"
[ "${FLEET_BAD:-0}" -gt 0 ] && failures="$failures\n- FLEET DEGRADED: ${FLEET_BAD} containers unhealthy/restarting"
[ "${HEADSCALE:-ok}" != "ok" ] && failures="$failures\n- HEADSCALE CONTROL PLANE DOWN"
[ "${SCRAPE_DOWN:-unknown}" = "unknown" ] && failures="$failures\n- MONITORING BLIND: VictoriaMetrics query failed"
[ "${SCRAPE_DOWN:-0}" -gt 2 ] && failures="$failures\n- SCRAPES FAILING: ${SCRAPE_DOWN} targets down"

if [ -n "$failures" ]; then
  curl -s -H "Title: SIS WATCHDOG: production degraded" -H "Priority: high" \
    -d "$(echo -e "$failures")" "$NTFY" > /dev/null
  echo "ALERT SENT:$failures"
else
  echo "ALL WATCHDOG CHECKS PASSED (offsite_age=${OFFSITE_AGE:-?}s fleet_bad=${FLEET_BAD:-0} scrape_down=${SCRAPE_DOWN:-0} headscale=${HEADSCALE:-ok})"
fi
