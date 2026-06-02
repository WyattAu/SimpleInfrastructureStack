#!/bin/bash
DATA_DIR=/mnt/pool_HDD_x2/infra/act-runner/data
FORGEJO_CONTAINER=operations-forgejo

CURRENT_IP=$(sudo docker inspect $FORGEJO_CONTAINER --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk '{print $1}')
if [ -z "$CURRENT_IP" ]; then echo "ERROR: no Forgejo IP"; exit 1; fi

for runner_dir in $DATA_DIR/*-k8s; do
  RUNNER_FILE="$runner_dir/.runner"
  [ ! -f "$RUNNER_FILE" ] && continue
  EXPECTED="http://$CURRENT_IP:3000"
  CURRENT=$(python3 -c "import json; print(json.load(open('$RUNNER_FILE')).get('address',''))" 2>/dev/null)
  if [ "$CURRENT" != "$EXPECTED" ]; then
    echo "Fix $(basename $runner_dir): $CURRENT -> $EXPECTED"
    python3 -c "import json; r=json.load(open('$RUNNER_FILE')); r['address']='$EXPECTED'; json.dump(r,open('$RUNNER_FILE','w'),indent=2)"
  fi
done
echo "OK. Forgejo=$CURRENT_IP"
