#!/usr/bin/env bash
# Install the docker0X cloud-init user-data snippets on the PVE node.
#
# Why this exists: the bpg/proxmox `proxmox_virtual_environment_file`
# resource uploads fine but its read-back fails against a `dir` datastore
# on PVE 9.2, so the snippets are managed outside Terraform state.
#
# Also fixes a real defect found 2026-11-23: the original snippet was
# generated from a Terraform heredoc whose `${}` interpolation left ragged
# indentation, making the YAML unparseable. cloud-init then silently fell
# back to an empty config (no user, no SSH key, hostname "ubuntu").
# This script validates every file with a YAML parser before shipping it,
# so a broken snippet can never reach a VM again.
#
# Usage: ops/hosting/deploy-cloudinit.sh [node-host]
# Key: HOSTING01_DEPLOY_KEY (default ~/.config/opencode/keys/hosting01-deploy-ed25519)
set -euo pipefail

NODE="${1:-192.168.0.120}"
KEY="${HOSTING01_DEPLOY_KEY:-$HOME/.config/opencode/keys/hosting01-deploy-ed25519}"
DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR=/var/lib/vz/snippets
SSH=(ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o IdentitiesOnly=yes -i "$KEY")
SCP=(scp -o StrictHostKeyChecking=no -o BatchMode=yes -o IdentitiesOnly=yes -i "$KEY")

for f in "$DIR"/docker0*-user-data.yaml "$DIR"/tradebot-user-data.yaml; do
  python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f"
  name="$(basename "$f")"
  "${SCP[@]}" -q "$f" "root@${NODE}:${DEST_DIR}/${name}"
  "${SSH[@]}" "root@${NODE}" "chmod 0644 ${DEST_DIR}/${name} && wc -c ${DEST_DIR}/${name}"
done

echo "snippets installed; run 'qm cloudinit update <vmid>' (or rebuild) to regenerate a drive"
