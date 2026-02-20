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

# Auto-detect key: prefer ed25519 (OCI Bastion works best with it), fall back to id_rsa
if [ -z "${SSH_KEY_PATH:-}" ]; then
  if [ -f "$HOME/.ssh/id_ed25519" ]; then
    SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
  elif [ -f "$HOME/.ssh/id_rsa" ]; then
    SSH_KEY_PATH="$HOME/.ssh/id_rsa"
  else
    echo "❌ No SSH key found. Set SSH_KEY_PATH or create ~/.ssh/id_ed25519"
    exit 1
  fi
fi

# The tunnel runs in the background (no TTY), so it cannot prompt for a passphrase.
# Ensure the key is loaded in the SSH agent now, while we still have a TTY.
KEY_FP=$(ssh-keygen -lf "${SSH_KEY_PATH}.pub" 2>/dev/null | awk '{print $2}')
if ! ssh-add -l 2>/dev/null | grep -qF "$KEY_FP"; then
  echo "🔑 SSH key not in agent — adding now (you may be prompted for your passphrase)..."
  ssh-add "$SSH_KEY_PATH"
fi
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
  -o IdentitiesOnly=yes \
  -o Ciphers=aes128-ctr,aes192-ctr,aes256-ctr \
  -N -L "${LOCAL_PORT}:${NODE_IP}:22" \
  -p 22 "$BASTION_ENDPOINT" &
TUNNEL_PID=$!

echo -n "🔗 Waiting for tunnel on localhost:${LOCAL_PORT}..."
TUNNEL_UP=false
for _ in $(seq 1 12); do
  sleep 2
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo ""
    echo "❌ SSH tunnel process exited unexpectedly. Check that SSH_KEY_PATH points to the correct key."
    echo "   Default: SSH_KEY_PATH=${SSH_KEY_PATH}"
    exit 1
  fi
  if nc -z localhost "$LOCAL_PORT" 2>/dev/null; then
    TUNNEL_UP=true
    break
  fi
  echo -n "."
done
if [ "$TUNNEL_UP" != "true" ]; then
  echo ""
  echo "❌ Tunnel did not become ready after 24 seconds."
  exit 1
fi
echo " ✓"

echo "🖥️  Connecting to ${NODE_IP} (ubuntu@localhost:${LOCAL_PORT})..."
echo "   (session TTL: 1 hour — type 'exit' to close)"
echo ""
ssh -i "$SSH_KEY_PATH" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ControlPath=none \
  -o IdentitiesOnly=yes \
  -p "$LOCAL_PORT" ubuntu@localhost
