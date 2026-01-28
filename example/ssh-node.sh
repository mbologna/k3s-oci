#!/usr/bin/env bash
# Opens an interactive SSH session to any k3s node via OCI Bastion port-forwarding.
# Run from the example/ directory after a successful tofu apply.
#
# Usage:
#   ./ssh-node.sh                        # SSH into the first server (default)
#   ./ssh-node.sh 10.0.1.82              # SSH into a specific private IP
#   ./ssh-node.sh worker                 # SSH into the standalone worker
#   ./ssh-node.sh server2                # SSH into the second server
#
# Override SSH key: SSH_KEY_PATH=~/.ssh/id_ed25519 ./ssh-node.sh
set -euo pipefail

SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"
LOCAL_PORT=22223

BASTION_OCID=$(tofu output -raw bastion_ocid)

# Resolve target IP
TARGET="${1:-server1}"
case "$TARGET" in
  server1) NODE_IP=$(tofu output -json k3s_servers_private_ips | jq -r '.[0]') ;;
  server2) NODE_IP=$(tofu output -json k3s_servers_private_ips | jq -r '.[1]') ;;
  server3) NODE_IP=$(tofu output -json k3s_servers_private_ips | jq -r '.[2]') ;;
  worker)  NODE_IP=$(tofu output -raw k3s_worker_private_ip) ;;
  *)       NODE_IP="$TARGET" ;;  # treat as raw IP
esac

echo "🔐 Creating OCI Bastion port-forwarding session to ${NODE_IP}:22..."
SESSION_OCID=$(oci bastion session create-port-forwarding \
  --bastion-id "$BASTION_OCID" \
  --ssh-public-key-file "${SSH_KEY_PATH}.pub" \
  --target-private-ip "$NODE_IP" \
  --target-port 22 \
  --session-ttl 3600 \
  --query 'data.id' --raw-output)

echo "   Session: $SESSION_OCID"
echo -n "⏳ Waiting for session to become ACTIVE..."
while true; do
  STATE=$(oci bastion session get --session-id "$SESSION_OCID" \
    --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "UNKNOWN")
  [ "$STATE" = "ACTIVE" ] && break
  echo -n "."
  sleep 5
done
echo " ✓"

RAW_CMD=$(oci bastion session get --session-id "$SESSION_OCID" \
  --query 'data."ssh-metadata".command' --raw-output)
BASTION_ENDPOINT=$(echo "$RAW_CMD" | grep -oE 'ocid1\.bastionsession\.[^ ]+@host\.bastion\.[^ ]+')

# Open tunnel in background; clean up on exit
TUNNEL_PID=""
cleanup() { [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true; }
trap cleanup EXIT

ssh -i "$SSH_KEY_PATH" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ControlPath=none \
  -o Ciphers=aes128-ctr,aes192-ctr,aes256-ctr \
  -N -L "${LOCAL_PORT}:${NODE_IP}:22" \
  -p 22 "$BASTION_ENDPOINT" &
TUNNEL_PID=$!

echo -n "🔗 Waiting for tunnel on localhost:${LOCAL_PORT}..."
for _ in $(seq 1 12); do
  sleep 2
  nc -z localhost "$LOCAL_PORT" 2>/dev/null && break
  echo -n "."
done
echo " ✓"

echo "🖥️  Connecting to ${NODE_IP} (ubuntu@localhost:${LOCAL_PORT})..."
echo "   (session TTL: 1 hour — type 'exit' to close)"
echo ""
ssh -i "$SSH_KEY_PATH" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ControlPath=none \
  -p "$LOCAL_PORT" ubuntu@localhost
