#!/usr/bin/env bash
# scripts/setup-longhorn-backup.sh
# Interactive helper to wire Longhorn backups to OCI Object Storage.
# Use this when neither create_longhorn_backup_user nor user_ocid is set in tfvars
# (manual Customer Secret Key workflow). Prefer create_longhorn_backup_user = true:
# Terraform then creates a bucket-scoped service user and cloud-init does all of this.
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
echo "  A Customer Secret Key carries EVERY permission of its user and is stored in the"
echo "  cluster — never generate it for an admin user. Use a service user whose only"
echo "  group policy is:"
echo "    Allow group <group> to read buckets in tenancy where target.bucket.name='${BUCKET}'"
echo "    Allow group <group> to manage objects in tenancy where target.bucket.name='${BUCKET}'"
echo "  (create_longhorn_backup_user = true in tfvars creates exactly this for you.)"
echo "  Then: OCI Console → Identity → Users → <service-user> → Customer Secret Keys"
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
# The bucket lives in the cluster's region, which is not necessarily the tenancy
# home region. Prefer an explicit OCI_REGION, then the OCI CLI profile's region.
OCI_REGION="${OCI_REGION:-$(awk -F= -v p="[${OCI_CLI_PROFILE:-DEFAULT}]" \
  '$0==p{f=1;next} /^\[/{f=0} f && $1~/^region/{gsub(/[ \t]/,"",$2); print $2; exit}' \
  "${OCI_CLI_CONFIG_FILE:-${HOME}/.oci/config}" 2>/dev/null || true)}"

if [[ -z "${OCI_REGION}" ]]; then
  read -r -p "Enter the cluster's OCI region (e.g. eu-frankfurt-1): " OCI_REGION
fi
echo "  Region:    ${OCI_REGION} (override with OCI_REGION=...)"

ENDPOINT="https://${OCI_NAMESPACE}.compat.objectstorage.${OCI_REGION}.oraclecloud.com"
BACKUP_TARGET="s3://${BUCKET}@${OCI_REGION}/"

echo ""
echo "Step 2: Creating Kubernetes secret (longhorn-backup-secret in longhorn-system)..."
# AWS_ENDPOINTS is required for OCI S3-compatible storage.
# Longhorn reads the custom endpoint from this key in the credential secret.
# There is no 's3-compatible-endpoint' Longhorn Setting — endpoint goes in the secret.
kubectl create secret generic longhorn-backup-secret \
  --from-literal=AWS_ACCESS_KEY_ID="${ACCESS_KEY_ID}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${SECRET_KEY}" \
  --from-literal=AWS_ENDPOINTS="${ENDPOINT}" \
  -n longhorn-system \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  Secret created (with AWS_ENDPOINTS=${ENDPOINT})."

echo ""
echo "Step 3: Patching the Longhorn BackupTarget 'default'..."
# Longhorn >= 1.8 uses the BackupTarget CR; the backup-target Settings were removed.
kubectl -n longhorn-system patch backuptargets.longhorn.io default --type merge \
  -p "{\"spec\":{\"backupTargetURL\":\"${BACKUP_TARGET}\",\"credentialSecret\":\"longhorn-backup-secret\"}}"
echo "  BackupTarget patched."

echo ""
echo "Step 4: Verifying backup target connectivity..."
sleep 15
BACKUP_AVAILABLE=$(kubectl -n longhorn-system get backuptargets.longhorn.io default \
  -o jsonpath='{.status.available}' 2>/dev/null || echo "unknown")

if [[ "${BACKUP_AVAILABLE}" == "true" ]]; then
  echo "  ✅ Backup target is reachable: ${BACKUP_TARGET}"
else
  echo "  ⚠️  Backup target available=${BACKUP_AVAILABLE:-unknown}"
  echo "     Check: kubectl -n longhorn-system get backuptargets default -o yaml (status.conditions)"
  echo "     Common issues: wrong region/endpoint, missing bucket, invalid credentials."
fi

echo ""
echo "Step 5: Applying the daily-backup RecurringJob (same as the automated path)..."
# Backs up every volume in the "default" group (all volumes unless relabelled).
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: daily-backup
  namespace: longhorn-system
spec:
  task: backup
  cron: "${LONGHORN_BACKUP_SCHEDULE:-30 0 * * *}"
  groups:
    - default
  retain: ${LONGHORN_BACKUP_RETAIN:-7}
  concurrency: 1
EOF

echo ""
echo "=== Setup complete ==="
echo "  Backup target: ${BACKUP_TARGET}"
echo "  S3 endpoint:   ${ENDPOINT}"
echo "  Credentials:   longhorn-backup-secret (in longhorn-system)"
echo "  Schedule:      daily-backup (${LONGHORN_BACKUP_SCHEDULE:-30 0 * * *} UTC, retain ${LONGHORN_BACKUP_RETAIN:-7})"
echo ""
echo "To back up a volume right away: Longhorn UI → Volume → <volume> → Create Backup."
echo "List backups: kubectl -n longhorn-system get backups.longhorn.io"
