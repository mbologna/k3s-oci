#!/usr/bin/env bash
# Opens an interactive SSH session to any k3s node via OCI Bastion port-forwarding.
# Run from the example/ directory after a successful tofu apply.
#
# Usage:
#   ./ssh-node.sh                  # SSH into the first server (default)
#   ./ssh-node.sh 10.0.1.82        # SSH into a specific private IP
#   ./ssh-node.sh worker           # SSH into the standalone worker
#   ./ssh-node.sh server2          # SSH into the second server
#
# Override SSH key:  SSH_KEY_PATH=~/.ssh/id_ed25519 ./ssh-node.sh
set -euo pipefail

SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"

BASTION_OCID=$(tofu output -raw bastion_ocid 2>/dev/null || true)
if [ -z "$BASTION_OCID" ]; then
  echo "❌ bastion_ocid is not set — enable_bastion = true required in terraform.tfvars"
  exit 1
fi

TARGET="${1:-server1}"
case "$TARGET" in
  server1) NODE_IP=$(tofu output -json k3s_servers_private_ips | jq -r '.[0]') ;;
  server2) NODE_IP=$(tofu output -json k3s_servers_private_ips | jq -r '.[1]') ;;
  server3) NODE_IP=$(tofu output -json k3s_servers_private_ips | jq -r '.[2]') ;;
  worker)  NODE_IP=$(tofu output -raw k3s_standalone_worker_private_ip) ;;
  *)       NODE_IP="$TARGET" ;;
esac

echo "🔐 Creating OCI Bastion port-forwarding session to ${NODE_IP}:22..."
SESSION_OCID=$(oci bastion session create-port-forwarding \
  --bastion-id "$BASTION_OCID" \
  --ssh-public-key-file "${SSH_KEY}.pub" \
  --target-private-ip "$NODE_IP" \
  --target-port 22 \
  --session-ttl 3600 \
  --query 'data.id' --raw-output)

echo -n "⏳ Waiting for session to become ACTIVE..."
while true; do
  STATE=$(oci bastion session get --session-id "$SESSION_OCID" \
    --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "UNKNOWN")
  [ "$STATE" = "ACTIVE" ] && break
  echo -n "."
  sleep 5
done
echo " ✓"

BASTION_ENDPOINT=$(oci bastion session get --session-id "$SESSION_OCID" \
  --query 'data."ssh-metadata".command' --raw-output \
  | grep -oE 'ocid1\.bastionsession\.[^ ]+@host\.bastion\.[^ ]+')

echo "🖥️  Connecting to ${NODE_IP}..."
echo "   (session TTL: 1 hour — type 'exit' to close)"
echo ""
# ProxyCommand with -W (stdio forward) avoids the background-tunnel race condition:
# nc -z would succeed as soon as SSH binds the local port, before the bastion
# connection is actually established. -W makes the outer SSH wait for the full
# end-to-end connection before handing over the interactive session.
ssh -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o IdentitiesOnly=yes \
  -o "ProxyCommand=ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -W %h:22 -p 22 $BASTION_ENDPOINT" \
  ubuntu@"$NODE_IP"
