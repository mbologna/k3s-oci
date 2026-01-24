#!/usr/bin/env bash
# Imports any OCI resources that were created in a previous apply but not
# recorded in state (e.g. due to a network error on the API response), then
# runs tofu apply -auto-approve.  Without this, name-keyed resources (dynamic
# group, IAM policy, log group) cause 409-Conflict on every subsequent apply.
#
# Usage: ./apply.sh [extra tofu flags]

set -uo pipefail

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

# ── Apply ──────────────────────────────────────────────────────────────────────
exec tofu apply -auto-approve "$@"
