#!/usr/bin/env bash
# Retrieves kubeconfig from the first k3s server via OCI Bastion Service.
# Run from the example/ directory after a successful tofu apply.
#
# Uses a port-forwarding session (no OCI Agent Bastion plugin required).
#
# Requirements: oci CLI, tofu, jq, ssh
# Override SSH key:  SSH_KEY_PATH=~/.ssh/id_ed25519 ./get-kubeconfig.sh
# Override output:   KUBECONFIG_OUT=~/.kube/custom.yaml ./get-kubeconfig.sh
set -euo pipefail

SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/.kube/k3s-oci.yaml}"
LOCAL_PORT=22222

tfvar() { grep -E "^[[:space:]]*$1[[:space:]]*=" terraform.tfvars | awk -F'"' '{print $2}'; }

BASTION_OCID=$(tofu output -raw bastion_ocid)
NLB_IP=$(tofu output -json public_nlb_ip | jq -r '.[0]')
SERVER_IP=$(tofu output -json k3s_servers_private_ips | jq -r '.[0]')

echo "🔐 Creating OCI Bastion port-forwarding session to ${SERVER_IP}:22..."
SESSION_OCID=$(oci bastion session create-port-forwarding \
  --bastion-id "$BASTION_OCID" \
  --ssh-public-key-file "${SSH_KEY_PATH}.pub" \
  --target-private-ip "$SERVER_IP" \
  --target-port 22 \
  --session-ttl 1800 \
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

# Extract the bastion endpoint (SESSION_OCID@host.bastion.REGION.oci.oraclecloud.com)
RAW_CMD=$(oci bastion session get --session-id "$SESSION_OCID" \
  --query 'data."ssh-metadata".command' --raw-output)
BASTION_ENDPOINT=$(echo "$RAW_CMD" | grep -oE 'ocid1\.bastionsession\.[^ ]+@host\.bastion\.[^ ]+')

# Open SSH tunnel in background; clean up on exit
TUNNEL_PID=""
cleanup() { [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true; }
trap cleanup EXIT

ssh -i "$SSH_KEY_PATH" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ControlPath=none \
  -o Ciphers=aes128-ctr,aes192-ctr,aes256-ctr \
  -N -L "${LOCAL_PORT}:${SERVER_IP}:22" \
  -p 22 "$BASTION_ENDPOINT" &
TUNNEL_PID=$!

echo -n "🔗 Waiting for tunnel on localhost:${LOCAL_PORT}..."
for _ in $(seq 1 12); do
  sleep 2
  nc -z localhost "$LOCAL_PORT" 2>/dev/null && break
  echo -n "."
done
echo " ✓"

echo "📥 Fetching kubeconfig..."
ssh -i "$SSH_KEY_PATH" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -p "$LOCAL_PORT" ubuntu@localhost \
  "sudo cat /etc/rancher/k3s/k3s.yaml" \
  2>/dev/null \
  | sed "s|https://127.0.0.1:6443|https://${NLB_IP}:6443|" \
  > "$KUBECONFIG_OUT"

echo "✅ Kubeconfig written to ${KUBECONFIG_OUT}"
echo ""
echo "   export KUBECONFIG=${KUBECONFIG_OUT}"
echo "   kubectl get nodes"
