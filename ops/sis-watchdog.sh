#!/bin/bash
# SIS meta-watchdog v5 - CachyOS-resident, independent of TrueNAS monitoring stack.
NTFY="https://ntfy.sh/wyattau-infra-0e92568ce5d04343c3b796ed558a04b9"
# Estate eventbusd (dogfood wave 2): durable watchdog event history.
EVENTBUS="http://192.168.1.3:9004"
EVENTBUS_TOKEN="dfaa082b14da2ed417a7b497de8f08a686c4148021562fd6ff608fb3f3ea7230"
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
# Config-drift checks (research loop iter 22): deploy.sh does
# `git reset --hard origin/main`, so uncommitted edits or local commits
# on the TrueNAS checkout are wiped silently at the next push. The Oct-11
# incident class. Any drift here must be upstreamed or deliberately
# discarded — silence is NOT health for a force-synced checkout.
REPO=/mnt/pool_HDD_x2/infra/stacks
DIRTY=$(git -C "$REPO" status --porcelain 2>/dev/null | wc -l)
AHEAD=$(git -C "$REPO" rev-list origin/main..HEAD --count 2>/dev/null || echo 0)
echo "DRIFT_DIRTY=${DIRTY:-unknown}"
echo "DRIFT_AHEAD=${AHEAD:-0}"
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
[ "${DRIFT_DIRTY:-0}" -gt 0 ] && failures="$failures\n- CHECKOUT DRIFT: ${DRIFT_DIRTY} uncommitted file(s) on the TrueNAS checkout — deploy will WIPE them (upstream first)"
[ "${DRIFT_AHEAD:-0}" -gt 0 ] && failures="$failures\n- CHECKOUT DRIFT: ${DRIFT_AHEAD} local commit(s) ahead of origin — deploy will reset them away (push or rebase)"

# --- dead-man switch (research loop iter 23) ---------------------------------
# docker01's watchdog heartbeats hosting.watchdog.* to eventbusd every
# 15 minutes. A dead host or dead timer is SILENT by construction, so the
# ABSENCE of the beat is itself the alert (healthchecks.io model: Late,
# then Down after grace). 2700s = two missed 15-min beats + slack. An
# unreadable query fails visible, like SCRAPE_DOWN=unknown.
HEARTBEAT_INFO=$(curl -s --max-time 8 -H "Authorization: Bearer $EVENTBUS_TOKEN" \
  "$EVENTBUS/events?topic=hosting.watchdog" | python3 -c '
import sys, json, datetime
try:
    events = json.load(sys.stdin)
    if not isinstance(events, list):
        raise ValueError("unexpected shape")
    stamps = []
    for e in events:
        if isinstance(e, dict) and e.get("timestamp"):
            try:
                stamps.append(datetime.datetime.fromisoformat(str(e["timestamp"]).replace("Z", "+00:00")))
            except ValueError:
                pass
    if not stamps:
        print("none")
    else:
        now = datetime.datetime.now(datetime.timezone.utc)
        print(f"age={int((now - max(stamps)).total_seconds())}")
except Exception:
    print("unreadable")
' 2>/dev/null)
case "$HEARTBEAT_INFO" in
  age=*) HB_AGE=${HEARTBEAT_INFO#age=} ;;
  *)     HB_AGE="$HEARTBEAT_INFO" ;;
esac
[ "$HB_AGE" = "unreadable" ] && failures="$failures\n- WATCHDOG HEARTBEAT UNREADABLE: eventbusd heartbeat query failed (wrong path? token?)"
[ "$HB_AGE" = "none" ] && failures="$failures\n- WATCHDOG HEARTBEAT MISSING: docker01 watchdog has never emitted (hosting_eventbus_* wiring on docker01?)"
case "$HB_AGE" in
  ""|unreadable|none) ;;
  *)
    if [ "$HB_AGE" -gt 2700 ] 2>/dev/null; then
      failures="$failures\n- DOCKER01 WATCHDOG SILENT: last heartbeat $((HB_AGE / 60))min ago — host down or watchdog timer dead"
    fi
    ;;
esac

emit_event() {
  # emit_event <topic> <payload-json>; failure is never fatal
  curl -s --max-time 5 -X POST "$EVENTBUS/publish/$1" \
    -H "Authorization: Bearer $EVENTBUS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$2" > /dev/null || true
}

if [ -n "$failures" ]; then
  curl -s -H "Title: SIS WATCHDOG: production degraded" -H "Priority: high" \
    -d "$(echo -e "$failures")" "$NTFY" > /dev/null
  FAILURES_JSON=$(printf '%s' "$failures" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '{}')
  emit_event "sis.watchdog.degraded" "{\"failures\": $FAILURES_JSON, \"at\": \"$(date -Is)\"}"
  echo "ALERT SENT:$failures"
else
  emit_event "sis.watchdog.healthy" "{\"at\": \"$(date -Is)\", \"offsite_age\": ${OFFSITE_AGE:-0}, \"fleet_bad\": ${FLEET_BAD:-0}, \"scrape_down\": ${SCRAPE_DOWN:-0}, \"heartbeat_age\": ${HB_AGE:-0}}"
  echo "ALL WATCHDOG CHECKS PASSED (offsite_age=${OFFSITE_AGE:-?}s fleet_bad=${FLEET_BAD:-0} scrape_down=${SCRAPE_DOWN:-0} headscale=${HEADSCALE:-ok} heartbeat_age=${HB_AGE:-?})"
fi
