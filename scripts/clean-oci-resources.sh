#!/usr/bin/env bash
# Delete orphaned OCI resources left over from a failed/partial destroy.
# Handles compute instances, load balancers, and networking resources that may
# have been removed from Terraform state (via `tofu state rm` for prevent_destroy
# resources) but still exist in OCI.
#
# Deletion order matters (children before parents):
#   instances → LBs → subnets → route tables → NAT/IGW → security lists → NSGs → VCN
#
# Idempotent: skips any resource not found.
# Conflict errors (409/412 — VNIC still attached) are retried with waits; this
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

log "Cleaning orphaned $CLUSTER OCI resources..."

# 0a. Terminate orphaned instances (removed from state but still running)
log "0a. Compute instances..."
for inst_name in "${CLUSTER}-standalone-worker"; do
  INST_ID=$(oci compute instance list --compartment-id "$COMPARTMENT" \
    --query "data[?\"display-name\"=='${inst_name}' && \"lifecycle-state\"!='TERMINATED'].id | [0]" \
    --raw-output 2>/dev/null || true)
  if [ -n "$INST_ID" ] && [ "$INST_ID" != "null" ]; then
    log "  Terminating $inst_name ($INST_ID)..."
    oci compute instance terminate --instance-id "$INST_ID" --preserve-boot-volume false --force 2>/dev/null || true
    # Wait for termination (max 5 min)
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      STATE=$(oci compute instance get --instance-id "$INST_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "TERMINATED")
      [ "$STATE" = "TERMINATED" ] && break
      log "    Waiting for $inst_name termination ($STATE, attempt $i/20)..."
      sleep 15
    done
  else
    log "  $inst_name: not found, skipping"
  fi
done

# 0b. Delete orphaned load balancers (removed from state but still active)
log "0b. Network load balancers..."
NLB_ID=$(oci nlb network-load-balancer list --compartment-id "$COMPARTMENT" \
  --query "data.items[?\"display-name\"=='${CLUSTER}-public-nlb' && \"lifecycle-state\"!='DELETED'].id | [0]" \
  --raw-output 2>/dev/null || true)
if [ -n "$NLB_ID" ] && [ "$NLB_ID" != "null" ]; then
  log "  Deleting ${CLUSTER}-public-nlb ($NLB_ID)..."
  oci nlb network-load-balancer delete --network-load-balancer-id "$NLB_ID" --force 2>/dev/null || true
  # Wait for deletion (max 3 min)
  for i in 1 2 3 4 5 6 7 8 9; do
    STATE=$(oci nlb network-load-balancer get --network-load-balancer-id "$NLB_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "DELETED")
    [ "$STATE" = "DELETED" ] && break
    log "    Waiting for NLB deletion ($STATE, attempt $i/9)..."
    sleep 20
  done
else
  log "  ${CLUSTER}-public-nlb: not found, skipping"
fi

log "0c. Internal load balancers..."
ILB_ID=$(oci lb load-balancer list --compartment-id "$COMPARTMENT" \
  --query "data[?\"display-name\"=='${CLUSTER}-internal-lb' && \"lifecycle-state\"!='DELETED'].id | [0]" \
  --raw-output 2>/dev/null || true)
if [ -n "$ILB_ID" ] && [ "$ILB_ID" != "null" ]; then
  log "  Deleting ${CLUSTER}-internal-lb ($ILB_ID)..."
  oci lb load-balancer delete --load-balancer-id "$ILB_ID" --force 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9; do
    STATE=$(oci lb load-balancer get --load-balancer-id "$ILB_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "DELETED")
    [ "$STATE" = "DELETED" ] && break
    log "    Waiting for internal LB deletion ($STATE, attempt $i/9)..."
    sleep 20
  done
else
  log "  ${CLUSTER}-internal-lb: not found, skipping"
fi

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

# 6. Network Security Groups (must be deleted before VCN)
log "6. Network Security Groups..."
for nsg_name in "${CLUSTER}-public-nlb-nsg" "${CLUSTER}-servers-nsg" "${CLUSTER}-workers-nsg"; do
  NSG_ID=$(oci network nsg list --compartment-id "$COMPARTMENT" \
    --query "data[?\"display-name\"=='${nsg_name}'].id | [0]" --raw-output 2>/dev/null || true)
  if [ -n "$NSG_ID" ] && [ "$NSG_ID" != "null" ]; then
    log "  Deleting $nsg_name ($NSG_ID)..."
    for attempt in 1 2 3; do
      if oci network nsg delete --nsg-id "$NSG_ID" --force 2>&1; then
        log "  $nsg_name: deleted"
        break
      fi
      log "  $nsg_name: failed (attempt $attempt), waiting 60s for VNICs to be released..."
      sleep 60
    done
  else
    log "  $nsg_name: not found, skipping"
  fi
done

# 7. VCN (also deletes default route table + default security list)
log "7. VCN..."
VCN_ID=$(oci network vcn list --compartment-id "$COMPARTMENT" \
  --query "data[?\"display-name\"=='${CLUSTER}-vcn'].id | [0]" --raw-output 2>/dev/null || true)
if [ -n "$VCN_ID" ] && [ "$VCN_ID" != "null" ]; then
  log "  Deleting ${CLUSTER}-vcn ($VCN_ID)..."
  oci network vcn delete --vcn-id "$VCN_ID" --force --wait-for-state TERMINATED 2>&1 || true
else
  log "  ${CLUSTER}-vcn: not found, skipping"
fi

log "OCI resource cleanup complete."
