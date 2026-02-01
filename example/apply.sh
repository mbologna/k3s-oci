#!/usr/bin/env bash
# 1. Imports any OCI resources orphaned by a previous failed apply (name-keyed
#    resources cause 409-Conflict if they exist in OCI but not in state).
# 2. Runs tofu apply, retrying up to MAX_ATTEMPTS times on transient OCI API
#    errors (e.g. "tls: bad record MAC" on the iaas endpoint — systematic on
#    first attempt, always recovers on retry).
#
# Usage: ./apply.sh [extra tofu flags]

set -uo pipefail

MAX_ATTEMPTS=3
RETRY_DELAY=10

# ── Read key values from terraform.tfvars ─────────────────────────────────────
tfvar() { grep -E "^[[:space:]]*$1[[:space:]]*=" terraform.tfvars | awk -F'"' '{print $2}'; }

TENANCY_OCID=$(tfvar tenancy_ocid)
COMPARTMENT_OCID=$(tfvar compartment_ocid)
CLUSTER_NAME=$(tfvar cluster_name)
DG_NAME=$(tfvar oci_identity_dynamic_group_name)
DG_NAME=${DG_NAME:-k3s-cluster-dynamic-group}
POLICY_NAME=$(tfvar oci_identity_policy_name)
POLICY_NAME=${POLICY_NAME:-k3s-cluster-policy}

# ── Import a resource if it exists in OCI but not in state ───────────────────
import_if_missing() {
  local addr="$1" ocid="$2"
  if [ -z "$ocid" ] || [ "$ocid" = "null" ]; then return 0; fi
  if ! tofu state show "$addr" >/dev/null 2>&1; then
    echo "  ↳ Importing orphaned resource: $addr"
    tofu import "$addr" "$ocid" || true
  fi
}

# ── Check for and import known orphan-prone resources ─────────────────────────
import_orphans() {
  echo "🔍 Checking for orphaned OCI resources not in state..."

  DG_OCID=$(oci iam dynamic-group list \
    --compartment-id "$TENANCY_OCID" \
    --query "data[?name=='${DG_NAME}'].id | [0]" \
    --raw-output 2>/dev/null || true)
  import_if_missing "module.k3s_cluster.oci_identity_dynamic_group.k3s" "$DG_OCID"

  POLICY_OCID=$(oci iam policy list \
    --compartment-id "$COMPARTMENT_OCID" \
    --query "data[?name=='${POLICY_NAME}'].id | [0]" \
    --raw-output 2>/dev/null || true)
  import_if_missing "module.k3s_cluster.oci_identity_policy.k3s" "$POLICY_OCID"

  LG_OCID=$(oci logging log-group list \
    --compartment-id "$COMPARTMENT_OCID" \
    --query "data[?\"display-name\"=='${CLUSTER_NAME}-logs'].id | [0]" \
    --raw-output 2>/dev/null || true)
  import_if_missing "module.k3s_cluster.oci_logging_log_group.k3s[0]" "$LG_OCID"

  WORKER_OCID=$(oci compute instance list \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "${CLUSTER_NAME}-standalone-worker" \
    --lifecycle-state RUNNING \
    --sort-by TIMECREATED --sort-order ASC \
    --query "data[0].id" \
    --raw-output 2>/dev/null || true)
  import_if_missing "module.k3s_cluster.oci_core_instance.k3s_standalone_worker[0]" "$WORKER_OCID"
}

# ── Apply with retry ───────────────────────────────────────────────────────────
import_orphans
attempt=0
until tofu apply -auto-approve "$@"; do
  exit_code=$?
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "❌ apply failed after $MAX_ATTEMPTS attempts (exit code: $exit_code)"
    exit "$exit_code"
  fi
  echo "⚠️  attempt $attempt failed — retrying in ${RETRY_DELAY}s..."
  sleep "$RETRY_DELAY"
  import_orphans
done
