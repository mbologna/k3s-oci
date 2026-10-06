#!/usr/bin/env bash
# Opens an interactive SSH session to a k3s node.
#
# Modes (auto-detected):
#   bastion  — enable_bastion = true: port-forwards via OCI Bastion Service
#   direct   — expose_ssh = true:     jumps through the public NLB (port 22)
#
# Run from the example/ directory after a successful tofu apply.
#
# Usage:
#   ./ssh-node.sh                  # SSH into the server (default)
#   ./ssh-node.sh worker           # SSH into the standalone worker
#   ./ssh-node.sh 10.0.1.82        # SSH into a specific private IP
#
# Override SSH key:  SSH_KEY_PATH=~/.ssh/id_ed25519 ./ssh-node.sh
set -euo pipefail

SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"

TARGET="${1:-server}"
case "$TARGET" in
  server)  NODE_IP=$(tofu output -json k3s_servers_private_ips | jq -r '.[0]') ;;
  worker)  NODE_IP=$(tofu output -raw k3s_standalone_worker_private_ip) ;;
  *)       NODE_IP="$TARGET" ;;
esac

SSH_BASE_OPTS=(-i "$SSH_KEY"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o IdentitiesOnly=yes)

BASTION_OCID=$(tofu output -raw bastion_ocid 2>/dev/null || true)
if [ -z "$BASTION_OCID" ]; then
  # ── direct mode: the NLB forwards port 22 to any node; -W hops to the target ──
  if [ "$(tofu output -raw ssh_command 2>/dev/null || true)" = "" ]; then
    echo "❌ Neither enable_bastion nor expose_ssh is set in terraform.tfvars"
    exit 1
  fi
  NLB_IP=$(tofu output -json public_nlb_ip | jq -r '.[0]')
  echo "🖥️  Connecting to ${NODE_IP} via NLB ${NLB_IP}:22..."
  exec ssh "${SSH_BASE_OPTS[@]}" \
    -o "ProxyCommand=ssh ${SSH_BASE_OPTS[*]} -o ConnectTimeout=10 -W %h:%p ubuntu@${NLB_IP}" \
    ubuntu@"$NODE_IP"
fi

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
ssh "${SSH_BASE_OPTS[@]}" \
  -o "ProxyCommand=ssh ${SSH_BASE_OPTS[*]} -W %h:22 -p 22 $BASTION_ENDPOINT" \
  ubuntu@"$NODE_IP"
