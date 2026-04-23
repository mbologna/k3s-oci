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
# Key overrides:
#   BASTION_KEY=~/.ssh/id_ed25519  ./ssh-node.sh  # key used to auth to OCI Bastion
#   NODE_KEY=~/.ssh/id_ed25519  ./ssh-node.sh  # key used to auth to the node
#   SSH_KEY_PATH=~/.ssh/id_ed25519 ./ssh-node.sh  # sets both keys at once (legacy)
set -euo pipefail

# ── Key detection ──────────────────────────────────────────────────────────────
#
# OCI Bastion and node authorized_keys can use DIFFERENT keys:
#   BASTION_KEY — used to authenticate to the OCI Bastion tunnel.
#                 OCI Bastion supports ed25519 and RSA; ed25519 is preferred.
#   NODE_KEY    — used to authenticate to the k3s node over the tunnel.
#                 Must match the public key deployed by `tofu apply`
#                 (read from local.ssh_public_key in Terraform state).
#
# Auto-detection priority for NODE_KEY:
#   1. NODE_KEY env var
#   2. SSH_KEY_PATH env var (legacy, sets both)
#   3. public_key_path in terraform.tfvars (strip .pub)
#   4. ~/.ssh/id_ed25519 (Terraform default)
#   5. ~/.ssh/id_rsa (legacy fallback)
#
# Auto-detection priority for BASTION_KEY:
#   1. BASTION_KEY env var
#   2. SSH_KEY_PATH env var (legacy)
#   3. ~/.ssh/id_ed25519 (preferred by OCI Bastion)
#   4. NODE_KEY (fallback if ed25519 not available)

TFVARS="$(dirname "$0")/terraform.tfvars"

# Resolve NODE_KEY
if [ -z "${NODE_KEY:-}" ]; then
  if [ -n "${SSH_KEY_PATH:-}" ]; then
    NODE_KEY="$SSH_KEY_PATH"
  else
    PUB_PATH=""
    if [ -f "$TFVARS" ]; then
      PUB_PATH=$(grep -E '^\s*public_key_path\s*=' "$TFVARS" \
        | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | xargs 2>/dev/null || true)
      PUB_PATH="${PUB_PATH/#\~/$HOME}"
    fi
    if [ -n "$PUB_PATH" ] && [ -f "${PUB_PATH%.pub}" ]; then
      NODE_KEY="${PUB_PATH%.pub}"
    elif [ -f "$HOME/.ssh/id_ed25519" ]; then
      NODE_KEY="$HOME/.ssh/id_ed25519"
    elif [ -f "$HOME/.ssh/id_rsa" ]; then
      NODE_KEY="$HOME/.ssh/id_rsa"
    else
      echo "❌ No node SSH key found. Set NODE_KEY or add public_key_path to terraform.tfvars"
      exit 1
    fi
  fi
fi

# Resolve BASTION_KEY
if [ -z "${BASTION_KEY:-}" ]; then
  if [ -n "${SSH_KEY_PATH:-}" ]; then
    BASTION_KEY="$SSH_KEY_PATH"
  elif [ -f "$HOME/.ssh/id_ed25519" ]; then
    BASTION_KEY="$HOME/.ssh/id_ed25519"
  else
    BASTION_KEY="$NODE_KEY"
  fi
fi

echo "🔑 Bastion key: $BASTION_KEY"
echo "🔑 Node key:    $NODE_KEY"

# The tunnel runs in the background (no TTY), so it cannot prompt for a passphrase.
# Ensure both keys are loaded in the SSH agent now, while we still have a TTY.
# If no agent is running, start one for this session only.
if [ -z "${SSH_AUTH_SOCK:-}" ] || ! ssh-add -l >/dev/null 2>&1; then
  echo "ℹ️  No SSH agent detected — starting one for this session..."
  eval "$(ssh-agent -s)" >/dev/null
fi
for KEY in "$BASTION_KEY" "$NODE_KEY"; do
  KEY_FP=$(ssh-keygen -lf "${KEY}.pub" 2>/dev/null | awk '{print $2}')
  if ! ssh-add -l 2>/dev/null | grep -qF "$KEY_FP"; then
    echo "🔑 Adding $KEY to agent (you may be prompted for your passphrase)..."
    ssh-add "$KEY" || {
      echo "⚠️  Could not add $KEY to agent."
      echo "   If your key has a passphrase, the background tunnel will fail to authenticate."
      echo "   Fix: ssh-agent + ssh-add before running this script, or use a passphrase-less key."
    }
  fi
done

LOCAL_PORT=22223

BASTION_OCID=$(tofu output -raw bastion_ocid)

# Resolve target IP
TARGET="${1:-server1}"
case "$TARGET" in
  server1) NODE_IP=$(tofu output -json k3s_servers_private_ips | jq -r '.[0]') ;;
  server2) NODE_IP=$(tofu output -json k3s_servers_private_ips | jq -r '.[1]') ;;
  server3) NODE_IP=$(tofu output -json k3s_servers_private_ips | jq -r '.[2]') ;;
  worker)  NODE_IP=$(tofu output -raw k3s_standalone_worker_private_ip) ;;
  *)       NODE_IP="$TARGET" ;;  # treat as raw IP
esac

echo "🔐 Creating OCI Bastion port-forwarding session to ${NODE_IP}:22..."
SESSION_OCID=$(oci bastion session create-port-forwarding \
  --bastion-id "$BASTION_OCID" \
  --ssh-public-key-file "${BASTION_KEY}.pub" \
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
TUNNEL_LOG=$(mktemp)
cleanup() { [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true; rm -f "${TUNNEL_LOG:-}"; }
trap cleanup EXIT

ssh -i "$BASTION_KEY" \
  -F /dev/null \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ControlPath=none \
  -o IdentitiesOnly=yes \
  -o IPQoS=none \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -N -L "${LOCAL_PORT}:${NODE_IP}:22" \
  -p 22 "$BASTION_ENDPOINT" 2>"$TUNNEL_LOG" &
TUNNEL_PID=$!

echo -n "🔗 Waiting for tunnel on localhost:${LOCAL_PORT}..."
TUNNEL_UP=false
for _ in $(seq 1 12); do
  sleep 2
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo ""
    echo "❌ SSH tunnel to bastion exited unexpectedly."
    echo "   Bastion endpoint: $BASTION_ENDPOINT"
    echo "   Bastion key used: $BASTION_KEY"
    echo ""
    echo "   OCI-provided SSH command (for manual testing):"
    echo "   ${RAW_CMD/<privateKeyFilePath>/$BASTION_KEY}"
    echo ""
    echo "   Last SSH debug output:"
    tail -20 "$TUNNEL_LOG"
    rm -f "$TUNNEL_LOG"
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
ssh -i "$NODE_KEY" \
  -F /dev/null \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ControlPath=none \
  -o IdentitiesOnly=yes \
  -o IPQoS=none \
  -p "$LOCAL_PORT" ubuntu@localhost
