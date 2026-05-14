#!/usr/bin/env bash
# Retrieves kubeconfig from the first k3s server via OCI Bastion Service.
# Run from the example/ directory after a successful tofu apply.
#
# Requirements: oci CLI, tofu, jq, ssh
# Override SSH key:    SSH_KEY_PATH=~/.ssh/id_ed25519 ./get-kubeconfig.sh
# Override output:     KUBECONFIG_OUT=~/.kube/custom.yaml ./get-kubeconfig.sh
set -euo pipefail

SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/.kube/k3s-oci.yaml}"

BASTION_OCID=$(tofu output -raw bastion_ocid 2>/dev/null || true)
if [ -z "$BASTION_OCID" ]; then
  echo "❌ bastion_ocid is not set — enable_bastion = true required in terraform.tfvars"
  exit 1
fi

NLB_IP=$(tofu output -json public_nlb_ip | jq -r '.[0]')
SERVER_IP=$(tofu output -json k3s_servers_private_ips | jq -r '.[0]')

echo "🔐 Creating OCI Bastion port-forwarding session to ${SERVER_IP}:22..."
SESSION_OCID=$(oci bastion session create-port-forwarding \
  --bastion-id "$BASTION_OCID" \
  --ssh-public-key-file "${SSH_KEY}.pub" \
  --target-private-ip "$SERVER_IP" \
  --target-port 22 \
  --session-ttl 1800 \
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

echo "📥 Fetching kubeconfig..."
mkdir -p "$(dirname "$KUBECONFIG_OUT")"
ssh -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o IdentitiesOnly=yes \
  -o "ProxyCommand=ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -W %h:22 -p 22 $BASTION_ENDPOINT" \
  ubuntu@"$SERVER_IP" \
  "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s|https://127.0.0.1:6443|https://${NLB_IP}:6443|" \
  > "$KUBECONFIG_OUT"

echo "✅ Kubeconfig written to ${KUBECONFIG_OUT}"
echo ""
echo "   export KUBECONFIG=${KUBECONFIG_OUT}"
echo "   kubectl get nodes"
