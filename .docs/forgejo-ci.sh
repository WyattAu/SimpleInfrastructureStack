#!/bin/bash
# forgejo-ci.sh — Query Forgejo CI status from terminal
# Usage: ./forgejo-ci.sh [repo-name]

FORGEJO_URL="https://forgejo.wyattau.com"
TOKEN="fe17e0cfd5cfcdf114be57c9481f7d1906ee4a56"

if [ -n "$1" ]; then
  # Check specific repo
  REPO="$1"
  echo "=== CI Status: $REPO ==="
  curl -sS "${FORGEJO_URL}/api/v1/repos/${REPO}/actions/runs?limit=5" \
    -H "Authorization: token ${TOKEN}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
runs = data.get('workflow_runs', data) if isinstance(data, dict) else data
if isinstance(runs, list):
    for r in runs[:5]:
        s = r.get('status', '?')
        t = r.get('title', '?')[:40]
        created = r.get('created', '?')[:19]
        print(f'  {s:10} {t:40} {created}')
    if not runs:
        print('  No runs found')
"
else
  # List all repos with CI status
  echo "=== All Repos CI Status ==="
  echo ""
  REPOS=$(curl -sS "${FORGEJO_URL}/api/v1/repos/search?limit=50" \
    -H "Authorization: token ${TOKEN}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
repos = data.get('data', data) if isinstance(data, dict) else data
for r in repos:
    print(r['full_name'])
")
  
  for repo in $REPOS; do
    LATEST=$(curl -sS "${FORGEJO_URL}/api/v1/repos/${repo}/actions/runs?limit=1" \
      -H "Authorization: token ${TOKEN}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
runs = data.get('workflow_runs', data) if isinstance(data, dict) else data
if isinstance(runs, list) and runs:
    r = runs[0]
    print(f'{r.get(\"status\",\"?\"):10} {r.get(\"title\",\"?\")[:35]}')
else:
    print('NO CI')
" 2>/dev/null)
    printf "%-35s %s\n" "$repo" "$LATEST"
  done
fi
