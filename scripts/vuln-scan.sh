#!/usr/bin/env bash
# Weekly vulnerability scan — writes results to Prometheus textfile for vmalert.
# Runs via cron on TrueNAS: 0 4 * * 0 /mnt/pool_HDD_x2/infra/tools/vuln-scan.sh
set -euo pipefail

TEXTFILE_DIR="/mnt/pool_HDD_x2/tank/datasources/sis/appdata/monitoring/textfile-collector"
TMP_FILE="${TEXTFILE_DIR}/vuln_scan.prom.$$"
OUT_FILE="${TEXTFILE_DIR}/vuln_scan.prom"

# Ensure directory exists
mkdir -p "$TEXTFILE_DIR"

# Start writing metrics
{
echo "# HELP sis_vuln_scan_critical Total CRITICAL CVEs found in container"
echo "# TYPE sis_vuln_scan_critical gauge"
echo "# HELP sis_vuln_scan_high Total HIGH CVEs found in container"
echo "# TYPE sis_vuln_scan_high gauge"
echo "# HELP sis_vuln_scan_timestamp Unix timestamp of last scan"
echo "# TYPE sis_vuln_scan_timestamp gauge"
echo "# HELP sis_vuln_scan_total Total containers scanned"
echo "# TYPE sis_vuln_scan_total gauge"
} > "$TMP_FILE"

TOTAL=0
TOTAL_CRITICAL=0
TOTAL_HIGH=0

# Scan each running container
for cid in $(docker ps -q); do
    name=$(docker inspect "$cid" --format '{{.Name}}' | sed 's|/||')
    img=$(docker inspect "$cid" --format '{{.Config.Image}}')
    TOTAL=$((TOTAL + 1))

    # Run Trivy scan (CRITICAL + HIGH)
    result=$(docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock:ro \
        aquasec/trivy:latest \
        image --severity CRITICAL,HIGH --format json "$img" 2>/dev/null || echo '{}')

    # Count vulnerabilities
    critical=$(echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
count=0
for r in d.get('results',[]):
    for v in r.get('vulnerabilities',[]):
        if v.get('Severity')=='CRITICAL':
            count+=1
print(count)
" 2>/dev/null || echo 0)

    high=$(echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
count=0
for r in d.get('results',[]):
    for v in r.get('vulnerabilities',[]):
        if v.get('Severity')=='HIGH':
            count+=1
print(count)
" 2>/dev/null || echo 0)

    TOTAL_CRITICAL=$((TOTAL_CRITICAL + critical))
    TOTAL_HIGH=$((TOTAL_HIGH + high))

    {
    echo "sis_vuln_scan_critical{container=\"$name\"} $critical"
    echo "sis_vuln_scan_high{container=\"$name\"} $high"
    } >> "$TMP_FILE"

    [ "$critical" -gt 0 ] && echo "WARN: $name has $critical CRITICAL CVEs"
done

# Summary metrics
{
echo "sis_vuln_scan_timestamp $(date +%s)"
echo "sis_vuln_scan_total $TOTAL"
} >> "$TMP_FILE"

# Atomic write
mv "$TMP_FILE" "$OUT_FILE"
echo "Scan complete: $TOTAL containers, $TOTAL_CRITICAL CRITICAL, $TOTAL_HIGH HIGH"
