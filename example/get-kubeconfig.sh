#!/usr/bin/env bash
# Retrieves kubeconfig from the first k3s server via OCI Bastion Service.
# Run from the example/ directory after a successful tofu apply.
#
# Requirements: oci CLI, tofu, jq, ssh
# Override SSH key:  SSH_KEY_PATH=~/.ssh/id_ed25519 ./get-kubeconfig.sh
# Override output:   KUBECONFIG_OUT=~/.kube/custom.yaml ./get-kubeconfig.sh
set -euo pipefail

SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"
KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/.kube/k3s-oci.yaml}"

tfvar() { grep -E "^[[:space:]]*$1[[:space:]]*=" terraform.tfvars | awk -F'"' '{print $2}'; }

COMPARTMENT_OCID=$(tfvar compartment_ocid)
CLUSTER_NAME=$(tfvar cluster_name)
BASTION_OCID=$(tofu output -raw bastion_ocid)
NLB_IP=$(tofu output -json public_nlb_ip | jq -r '.[0]')
SERVER_IP=$(tofu output -json k3s_servers_private_ips | jq -r '.[0]')

echo "🔍 Finding instance OCID for ${SERVER_IP}..."
SERVER_OCID=$(oci compute instance list \
  --compartment-id "$COMPARTMENT_OCID" \
  --lifecycle-state RUNNING \
  --all --output json \
  | jq -r --arg c "$CLUSTER_NAME" \
    '[.data[] | select(.["display-name"] | endswith("-\($c)-servers"))] | sort_by(.["time-created"]) | .[0].id')

if [ -z "$SERVER_OCID" ] || [ "$SERVER_OCID" = "null" ]; then
  echo "❌ Could not find a RUNNING server instance for cluster '$CLUSTER_NAME'" >&2
  exit 1
fi

echo "🔐 Creating OCI Bastion managed-SSH session to ${SERVER_IP}..."
SESSION_OCID=$(oci bastion session create-managed-ssh \
  --bastion-id "$BASTION_OCID" \
  --ssh-public-key-file "${SSH_KEY_PATH}.pub" \
  --target-resource-id "$SERVER_OCID" \
  --target-os-username ubuntu \
  --session-ttl-in-seconds 1800 \
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

# Replace the <privateKeyFilePath> placeholder from OCI's template command
SSH_CMD="${RAW_CMD//<privateKeyFilePath>/${SSH_KEY_PATH}}"

# Extract the ProxyCommand and target IP from the OCI-provided command
PROXY_CMD=$(echo "$SSH_CMD" | grep -oE "ProxyCommand='[^']+'" | sed "s/ProxyCommand='//;s/'$//")
TARGET=$(echo "$SSH_CMD" | awk '{print $NF}')

echo "📥 Fetching kubeconfig..."
ssh -i "$SSH_KEY_PATH" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o "ProxyCommand=${PROXY_CMD}" \
  "$TARGET" \
  "sudo cat /etc/rancher/k3s/k3s.yaml" \
  2>/dev/null \
  | sed "s|https://127.0.0.1:6443|https://${NLB_IP}:6443|" \
  > "$KUBECONFIG_OUT"

echo "✅ Kubeconfig written to ${KUBECONFIG_OUT}"
echo ""
echo "   export KUBECONFIG=${KUBECONFIG_OUT}"
echo "   kubectl get nodes"
