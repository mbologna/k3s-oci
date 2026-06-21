#!/usr/bin/env bash
# scripts/setup-longhorn-backup.sh
# Interactive helper to wire Longhorn backups to OCI Object Storage.
# Use this when user_ocid is not set in tfvars (manual Customer Secret Key workflow).
#
# Usage:
#   COMPARTMENT_OCID=ocid1.tenancy.oc1..xxx ./scripts/setup-longhorn-backup.sh
#   # or via just:
#   COMPARTMENT_OCID=ocid1.tenancy.oc1..xxx just setup-longhorn-backup
#
# Prerequisites: kubectl configured, oci CLI configured, jq installed.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k3s-oci}"
COMPARTMENT_OCID="${COMPARTMENT_OCID:?Set COMPARTMENT_OCID to your OCI compartment/tenancy OCID}"

echo "=== Longhorn Backup Target Setup ==="
echo ""

# --- Get OCI namespace ---
echo "Fetching OCI Object Storage namespace..."
OCI_NAMESPACE=$(oci os ns get --compartment-id "${COMPARTMENT_OCID}" \
  --query 'data' --raw-output 2>/dev/null || \
  oci os ns get --query 'data' --raw-output 2>/dev/null)
BUCKET="${CLUSTER_NAME}-longhorn-backup"
echo "  Namespace: ${OCI_NAMESPACE}"
echo "  Bucket:    ${BUCKET}"

# --- Get or read Customer Secret Key ---
echo ""
echo "Step 1: Customer Secret Key"
echo "  Go to: OCI Console → Identity → Users → <your-user> → Customer Secret Keys"
echo "  Click 'Generate Secret Key', name it '${CLUSTER_NAME}-longhorn-backup'"
echo "  Copy both the Access Key and Secret immediately (secret shown once)."
echo ""

read -r -p "Enter Access Key ID: " ACCESS_KEY_ID
read -r -s -p "Enter Secret Key: " SECRET_KEY
echo ""

if [[ -z "${ACCESS_KEY_ID}" || -z "${SECRET_KEY}" ]]; then
  echo "ERROR: Access Key ID and Secret Key are required."
  exit 1
fi

# --- Determine OCI region ---
OCI_REGION=$(oci iam region-subscription list --tenancy-id "${COMPARTMENT_OCID}" \
  --query 'data[?["is-home-region"]==`true`]."region-name" | [0]' \
  --raw-output 2>/dev/null || \
  oci iam region list --query 'data[0]."name"' --raw-output 2>/dev/null || \
  echo "")

if [[ -z "${OCI_REGION}" ]]; then
  read -r -p "Enter OCI region (e.g. eu-frankfurt-1): " OCI_REGION
fi

ENDPOINT="https://${OCI_NAMESPACE}.compat.objectstorage.${OCI_REGION}.oraclecloud.com"
BACKUP_TARGET="s3://${BUCKET}@${OCI_REGION}/"

echo ""
echo "Step 2: Creating Kubernetes secret (longhorn-backup-secret in longhorn-system)..."
kubectl create secret generic longhorn-backup-secret \
  --from-literal=AWS_ACCESS_KEY_ID="${ACCESS_KEY_ID}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${SECRET_KEY}" \
  -n longhorn-system \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  Secret created."

echo ""
echo "Step 3: Applying Longhorn BackupTarget settings..."
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Setting
metadata:
  name: backup-target
  namespace: longhorn-system
value: "${BACKUP_TARGET}"
---
apiVersion: longhorn.io/v1beta2
kind: Setting
metadata:
  name: backup-target-credential-secret
  namespace: longhorn-system
value: "longhorn-backup-secret"
---
apiVersion: longhorn.io/v1beta2
kind: Setting
metadata:
  name: s3-compatible-endpoint
  namespace: longhorn-system
value: "${ENDPOINT}"
EOF
echo "  Longhorn settings applied."

echo ""
echo "Step 4: Verifying backup target connectivity..."
sleep 10
BACKUP_AVAILABLE=$(kubectl get setting backup-target-available \
  -n longhorn-system \
  -o jsonpath='{.value}' 2>/dev/null || echo "unknown")

if [[ "${BACKUP_AVAILABLE}" == "true" ]]; then
  echo "  ✅ Backup target is reachable: ${BACKUP_TARGET}"
else
  echo "  ⚠️  Backup target connectivity status: ${BACKUP_AVAILABLE}"
  echo "     Check Longhorn UI → Settings → Backup → Backup Target for errors."
  echo "     Common issues: wrong endpoint URL, missing bucket, invalid credentials."
fi

echo ""
echo "=== Setup complete ==="
echo "  Backup target: ${BACKUP_TARGET}"
echo "  S3 endpoint:   ${ENDPOINT}"
echo "  Credentials:   longhorn-backup-secret (in longhorn-system)"
echo ""
echo "To trigger an immediate backup of a volume:"
echo "  kubectl -n longhorn-system create -f - <<EOF"
echo "  apiVersion: longhorn.io/v1beta2"
echo "  kind: BackupVolume"
echo "  metadata:"
echo "    name: <pvc-name>"
echo "  EOF"
