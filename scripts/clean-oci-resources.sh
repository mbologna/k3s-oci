#!/usr/bin/env bash
# Delete orphaned OCI networking resources left over from a failed/partial destroy.
# Terraform state may be empty yet these resources still exist in OCI.
#
# Deletion order matters (children before parents):
#   subnet → non-default route tables → NAT gateway → non-default security lists → VCN
#
# Idempotent: skips any resource not found.
# Conflict errors (409 — VNIC still attached) are retried up to 3x with 60s wait; this
# happens when OCI instances are TERMINATED but VNICs haven't been fully released yet.
# Run from anywhere — requires oci CLI and COMPARTMENT_OCID env var.
set -euo pipefail

: "${COMPARTMENT_OCID:?COMPARTMENT_OCID must be set (your OCI tenancy or compartment OCID)}"
COMPARTMENT="$COMPARTMENT_OCID"
CLUSTER="${CLUSTER_NAME:-k3s-oci}"

log() { echo "[clean-oci-resources] $*"; }

delete_subnet() {
  local name="$1"
  local id
  id=$(oci network subnet list --compartment-id "$COMPARTMENT" \
    --query "data[?\"display-name\"=='${name}'].id | [0]" --raw-output 2>/dev/null || true)
  [ -z "$id" ] || [ "$id" = "null" ] && { log "  $name: not found, skipping"; return; }
  # Retry up to 3x: OCI takes time to release VNICs after instance TERMINATED
  for attempt in 1 2 3; do
    log "  Deleting $name ($id)... (attempt $attempt)"
    if oci network subnet delete --subnet-id "$id" --force --wait-for-state TERMINATED 2>&1; then
      log "  $name: deleted"
      return
    fi
    log "  $name: failed (attempt $attempt), waiting 60s for VNICs to be released..."
    sleep 60
  done
  log "  WARNING: Could not delete $name after 3 attempts — may have lingering VNICs"
}

log "Cleaning orphaned $CLUSTER OCI networking resources..."

# 1. Subnets
log "1. Subnets..."
delete_subnet "${CLUSTER}-private-subnet"
delete_subnet "${CLUSTER}-public-subnet"

# 2. Non-default route tables
log "2. Route tables..."
for rt_name in "${CLUSTER}-private-rt" "${CLUSTER}-public-rt"; do
  RT_ID=$(oci network route-table list --compartment-id "$COMPARTMENT" \
    --query "data[?\"display-name\"=='${rt_name}'].id | [0]" --raw-output 2>/dev/null || true)
  if [ -n "$RT_ID" ] && [ "$RT_ID" != "null" ]; then
    log "  Deleting $rt_name ($RT_ID)..."
    oci network route-table delete --rt-id "$RT_ID" --force --wait-for-state TERMINATED 2>&1 || true
  else
    log "  $rt_name: not found, skipping"
  fi
done

# 3. NAT gateway
log "3. NAT gateway..."
NAT_ID=$(oci network nat-gateway list --compartment-id "$COMPARTMENT" \
  --query "data[?\"display-name\"=='${CLUSTER}-natgw'].id | [0]" --raw-output 2>/dev/null || true)
if [ -n "$NAT_ID" ] && [ "$NAT_ID" != "null" ]; then
  log "  Deleting ${CLUSTER}-natgw ($NAT_ID)..."
  oci network nat-gateway delete --nat-gateway-id "$NAT_ID" --force --wait-for-state TERMINATED 2>&1 || true
else
  log "  ${CLUSTER}-natgw: not found, skipping"
fi

# 4. Internet gateway (if any)
log "4. Internet gateway..."
IGW_ID=$(oci network internet-gateway list --compartment-id "$COMPARTMENT" \
  --query "data[?\"display-name\"=='${CLUSTER}-igw'].id | [0]" --raw-output 2>/dev/null || true)
if [ -n "$IGW_ID" ] && [ "$IGW_ID" != "null" ]; then
  log "  Deleting ${CLUSTER}-igw ($IGW_ID)..."
  oci network internet-gateway delete --ig-id "$IGW_ID" --force --wait-for-state TERMINATED 2>&1 || true
else
  log "  ${CLUSTER}-igw: not found, skipping"
fi

# 5. Non-default security lists
log "5. Security lists..."
for sl_name in "${CLUSTER}-private-sl" "${CLUSTER}-public-sl"; do
  SL_ID=$(oci network security-list list --compartment-id "$COMPARTMENT" \
    --query "data[?\"display-name\"=='${sl_name}'].id | [0]" --raw-output 2>/dev/null || true)
  if [ -n "$SL_ID" ] && [ "$SL_ID" != "null" ]; then
    log "  Deleting $sl_name ($SL_ID)..."
    oci network security-list delete --security-list-id "$SL_ID" --force --wait-for-state TERMINATED 2>&1 || true
  else
    log "  $sl_name: not found, skipping"
  fi
done

# 6. VCN (also deletes default route table + default security list)
log "6. VCN..."
VCN_ID=$(oci network vcn list --compartment-id "$COMPARTMENT" \
  --query "data[?\"display-name\"=='${CLUSTER}-vcn'].id | [0]" --raw-output 2>/dev/null || true)
if [ -n "$VCN_ID" ] && [ "$VCN_ID" != "null" ]; then
  log "  Deleting ${CLUSTER}-vcn ($VCN_ID)..."
  oci network vcn delete --vcn-id "$VCN_ID" --force --wait-for-state TERMINATED 2>&1 || true
else
  log "  ${CLUSTER}-vcn: not found, skipping"
fi

log "OCI networking cleanup complete."
