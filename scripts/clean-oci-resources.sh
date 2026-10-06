#!/usr/bin/env bash
# Delete orphaned OCI resources left over from a failed/partial destroy.
# Handles ALL resource types created by the k3s-oci module: compute, load
# balancers, networking, storage, vaults, MySQL, logging, and IAM.
#
# Deletion order matters (children before parents):
#   logging agents → log groups → instance pools → instances → LBs →
#   MySQL → vault secrets → vaults → buckets → backup policies →
#   subnets → route tables → NAT/IGW →
#   security lists → NSGs → VCN → IAM
#
# Idempotent: skips any resource not found.
# Conflict errors (409/412 — VNIC still attached) are retried with waits; this
# happens when OCI instances are TERMINATED but VNICs haven't been fully released yet.
# Run from anywhere — requires oci CLI and COMPARTMENT_OCID env var.
# KEEP_VAULT=true skips the vault and its secrets: the module's vault has
# prevent_destroy, the tenancy allows few DEFAULT vaults, and a deleted vault
# blocks quota for 7+ days. Re-import it into the fresh state before tofu apply.
# KEEP_BUCKETS=true skips the <cluster>-terraform-state and <cluster>-longhorn-backup
# buckets, so etcd snapshots and Longhorn backups survive a rebuild (they are the
# restore source). Re-import both buckets and their lifecycle policies before tofu apply.
set -euo pipefail

: "${COMPARTMENT_OCID:?COMPARTMENT_OCID must be set (your OCI tenancy or compartment OCID)}"
COMPARTMENT="$COMPARTMENT_OCID"
CLUSTER="${CLUSTER_NAME:-k3s-oci}"
KEEP_VAULT="${KEEP_VAULT:-false}"
KEEP_BUCKETS="${KEEP_BUCKETS:-false}"
# IAM users/groups live in the tenancy root; defaults to COMPARTMENT_OCID (which is
# the tenancy when the cluster is deployed in the root compartment).
TENANCY="${TENANCY_OCID:-$COMPARTMENT}"

log() { echo "[clean-oci-resources] $*"; }

log "Cleaning orphaned $CLUSTER OCI resources..."

# ── Pre-networking: logging, MySQL, vaults, buckets, backups ─────────────────

# 0-log. Delete logging agent configurations, logs, and log groups
log "0-log. Logging resources..."
# Agent configurations reference log groups and must be deleted first
for agent in $(oci logging agent-configuration list --compartment-id "$COMPARTMENT" \
  --query "data[?contains(\"display-name\", '${CLUSTER}')].id" --raw-output 2>/dev/null \
  | jq -r '.[]' 2>/dev/null); do
  log "  Deleting agent configuration ($agent)..."
  oci logging agent-configuration delete --config-id "$agent" --force 2>/dev/null || true
done
# Individual logs within the log group
LOG_GROUP_ID=$(oci logging log-group list --compartment-id "$COMPARTMENT" \
  --query "data[?\"display-name\"=='${CLUSTER}-logs'].id | [0]" --raw-output 2>/dev/null || true)
if [ -n "$LOG_GROUP_ID" ] && [ "$LOG_GROUP_ID" != "null" ]; then
  for log_id in $(oci logging log list --log-group-id "$LOG_GROUP_ID" \
    --query 'data[].id' --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null); do
    log "  Deleting log ($log_id)..."
    oci logging log delete --log-group-id "$LOG_GROUP_ID" --log-id "$log_id" --force 2>/dev/null || true
  done
  log "  Deleting log group ${CLUSTER}-logs ($LOG_GROUP_ID)..."
  oci logging log-group delete --log-group-id "$LOG_GROUP_ID" --force 2>/dev/null || true
else
  log "  ${CLUSTER}-logs: not found, skipping"
fi

# 0-mysql. Delete MySQL DB systems
log "0-mysql. MySQL DB systems..."
for mysql_id in $(oci mysql db-system list --compartment-id "$COMPARTMENT" \
  --query "data[?\"display-name\"=='${CLUSTER}-mysql' && \"lifecycle-state\"!='DELETED'].id" \
  --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null); do
  log "  Deleting ${CLUSTER}-mysql ($mysql_id)..."
  oci mysql db-system delete --db-system-id "$mysql_id" --skip-final-backup true --force 2>/dev/null || true
  for i in $(seq 1 20); do
    STATE=$(oci mysql db-system get --db-system-id "$mysql_id" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "DELETED")
    [ "$STATE" = "DELETED" ] && break
    log "    Waiting for MySQL deletion ($STATE, attempt $i/20)..."
    sleep 15
  done
done

# 0-vault. Schedule ALL vaults for deletion
# OCI vaults have a 7-day minimum grace period — they cannot be instantly deleted.
# tofu apply creates a fresh vault; if the quota (~5) is hit, wait for old ones
# to fully delete or request a service limit increase.
log "0-vault. OCI Vaults..."
if [ "$KEEP_VAULT" = "true" ]; then
  log "  KEEP_VAULT=true — leaving ${CLUSTER}-vault and its secrets in place"
else
  VAULT_IDS=$(oci kms management vault list --compartment-id "$COMPARTMENT" \
    --query "data[?\"display-name\"=='${CLUSTER}-vault' && \"lifecycle-state\"=='ACTIVE'] | [].id" \
    --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null || true)
  VAULT_COUNT=0
  for vault_id in $VAULT_IDS; do
    VAULT_COUNT=$((VAULT_COUNT + 1))
    log "  Scheduling vault for deletion: $vault_id"
    # Delete all secrets in the vault first
    for secret_id in $(oci vault secret list --compartment-id "$COMPARTMENT" \
      --vault-id "$vault_id" \
      --query "data[?\"lifecycle-state\"!='DELETED' && \"lifecycle-state\"!='PENDING_DELETION'].id" \
      --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null); do
      log "    Scheduling secret for deletion: $secret_id"
      oci vault secret schedule-secret-deletion --secret-id "$secret_id" 2>/dev/null || true
    done
    oci kms management vault schedule-deletion --vault-id "$vault_id" 2>/dev/null || true
  done
  if [ "$VAULT_COUNT" -eq 0 ]; then
    log "  No vaults to clean up"
  fi
fi

# 0-bucket. Delete orphaned object storage buckets
log "0-bucket. Object Storage buckets..."
OS_NAMESPACE=$(oci os ns get --query 'data' --raw-output 2>/dev/null || true)
if [ "$KEEP_BUCKETS" = "true" ]; then
  log "  KEEP_BUCKETS=true — leaving ${CLUSTER}-terraform-state and ${CLUSTER}-longhorn-backup in place"
elif [ -n "$OS_NAMESPACE" ]; then
  for bucket_name in "${CLUSTER}-terraform-state" "${CLUSTER}-longhorn-backup"; do
    if oci os bucket get --bucket-name "$bucket_name" --namespace-name "$OS_NAMESPACE" &>/dev/null 2>&1; then
      log "  Emptying and deleting $bucket_name..."
      # Delete all objects AND noncurrent versions (versioned buckets refuse
      # deletion while any version remains; bulk-delete only removes current ones)
      oci os object bulk-delete --bucket-name "$bucket_name" --namespace-name "$OS_NAMESPACE" --force 2>/dev/null || true
      oci os object list-object-versions --bucket-name "$bucket_name" --namespace-name "$OS_NAMESPACE" --all 2>/dev/null |
        jq -r '(.data // [])[] | [.name, ."version-id"] | @tsv' 2>/dev/null |
        while IFS=$'\t' read -r name version_id; do
          oci os object delete --bucket-name "$bucket_name" --namespace-name "$OS_NAMESPACE" \
            --object-name "$name" --version-id "$version_id" --force 2>/dev/null || true
        done
      oci os bucket delete --bucket-name "$bucket_name" --namespace-name "$OS_NAMESPACE" --force 2>/dev/null || true
    else
      log "  $bucket_name: not found, skipping"
    fi
  done
fi

# 0-backup. Delete boot volume backup policies
log "0-backup. Boot volume backup policies..."
BACKUP_POLICY_ID=$(oci bv volume-backup-policy list --compartment-id "$COMPARTMENT" \
  --query "data[?\"display-name\"=='${CLUSTER}-weekly-backup'].id | [0]" --raw-output 2>/dev/null || true)
if [ -n "$BACKUP_POLICY_ID" ] && [ "$BACKUP_POLICY_ID" != "null" ]; then
  log "  Deleting ${CLUSTER}-weekly-backup ($BACKUP_POLICY_ID)..."
  oci bv volume-backup-policy delete --policy-id "$BACKUP_POLICY_ID" --force 2>/dev/null || true
else
  log "  ${CLUSTER}-weekly-backup: not found, skipping"
fi

# ── Compute and networking ────────────────────────────────────────────────────

# 0a. Terminate instance pools (servers are provisioned via instance pool)
log "0a. Instance pools..."
for pool_id in $(oci compute-management instance-pool list --compartment-id "$COMPARTMENT" \
  --query "data[?contains(\"display-name\", '${CLUSTER}') && \"lifecycle-state\"!='TERMINATED'].id" \
  --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null); do
  POOL_NAME=$(oci compute-management instance-pool get --instance-pool-id "$pool_id" \
    --query 'data."display-name"' --raw-output 2>/dev/null || echo "unknown")
  log "  Terminating pool $POOL_NAME ($pool_id)..."
  oci compute-management instance-pool terminate --instance-pool-id "$pool_id" --force 2>/dev/null || true
  for i in $(seq 1 20); do
    STATE=$(oci compute-management instance-pool get --instance-pool-id "$pool_id" \
      --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "TERMINATED")
    [ "$STATE" = "TERMINATED" ] && break
    log "    Waiting for pool termination ($STATE, attempt $i/20)..."
    sleep 15
  done
done
# Delete instance configurations used by the pools
for config_id in $(oci compute-management instance-configuration list --compartment-id "$COMPARTMENT" \
  --query "data[?contains(\"display-name\", '${CLUSTER}')].id" \
  --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null); do
  log "  Deleting instance configuration ($config_id)..."
  oci compute-management instance-configuration delete --instance-configuration-id "$config_id" --force 2>/dev/null || true
done

# 0b. Terminate orphaned standalone instances (removed from state but still running)
log "0b. Compute instances..."
for inst_id in $(oci compute instance list --compartment-id "$COMPARTMENT" \
  --query "data[?contains(\"display-name\", '${CLUSTER}') && \"lifecycle-state\"!='TERMINATED'].id" \
  --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null); do
  INST_NAME=$(oci compute instance get --instance-id "$inst_id" \
    --query 'data."display-name"' --raw-output 2>/dev/null || echo "unknown")
  log "  Terminating $INST_NAME ($inst_id)..."
  oci compute instance terminate --instance-id "$inst_id" --preserve-boot-volume false --force 2>/dev/null || true
  for i in $(seq 1 20); do
    STATE=$(oci compute instance get --instance-id "$inst_id" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "TERMINATED")
    [ "$STATE" = "TERMINATED" ] && break
    log "    Waiting for $INST_NAME termination ($STATE, attempt $i/20)..."
    sleep 15
  done
done

# 0c. Delete orphaned load balancers (removed from state but still active)
log "0c. Network load balancers..."
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

log "0d. Internal load balancers..."
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

# 1. Subnets (delete ALL matching — multiple VCNs may have identically-named subnets)
log "1. Subnets..."
for subnet_name in "${CLUSTER}-private-subnet" "${CLUSTER}-public-subnet"; do
  for SUBNET_ID in $(oci network subnet list --compartment-id "$COMPARTMENT" \
    --query "data[?\"display-name\"=='${subnet_name}'].id" --raw-output 2>/dev/null \
    | jq -r '.[]' 2>/dev/null); do
    for attempt in 1 2 3; do
      log "  Deleting $subnet_name ($SUBNET_ID)... (attempt $attempt)"
      if oci network subnet delete --subnet-id "$SUBNET_ID" --force --wait-for-state TERMINATED 2>&1; then
        break
      fi
      log "  $subnet_name: failed (attempt $attempt), waiting 60s for VNICs to be released..."
      sleep 60
    done
  done
done

# 2. Non-default route tables
log "2. Route tables..."
for rt_name in "${CLUSTER}-private-rt" "${CLUSTER}-public-rt"; do
  for RT_ID in $(oci network route-table list --compartment-id "$COMPARTMENT" \
    --query "data[?\"display-name\"=='${rt_name}'].id" --raw-output 2>/dev/null \
    | jq -r '.[]' 2>/dev/null); do
    log "  Deleting $rt_name ($RT_ID)..."
    oci network route-table delete --rt-id "$RT_ID" --force --wait-for-state TERMINATED 2>&1 || true
  done
done

# 3. NAT gateways
log "3. NAT gateways..."
for NAT_ID in $(oci network nat-gateway list --compartment-id "$COMPARTMENT" \
  --query "data[?\"display-name\"=='${CLUSTER}-natgw'].id" --raw-output 2>/dev/null \
  | jq -r '.[]' 2>/dev/null); do
  log "  Deleting ${CLUSTER}-natgw ($NAT_ID)..."
  oci network nat-gateway delete --nat-gateway-id "$NAT_ID" --force --wait-for-state TERMINATED 2>&1 || true
done

# 4. Internet gateways
log "4. Internet gateways..."
for IGW_ID in $(oci network internet-gateway list --compartment-id "$COMPARTMENT" \
  --query "data[?\"display-name\"=='${CLUSTER}-igw'].id" --raw-output 2>/dev/null \
  | jq -r '.[]' 2>/dev/null); do
  log "  Deleting ${CLUSTER}-igw ($IGW_ID)..."
  oci network internet-gateway delete --ig-id "$IGW_ID" --force --wait-for-state TERMINATED 2>&1 || true
done

# 5. Non-default security lists
log "5. Security lists..."
for sl_name in "${CLUSTER}-private-sl" "${CLUSTER}-public-sl"; do
  for SL_ID in $(oci network security-list list --compartment-id "$COMPARTMENT" \
    --query "data[?\"display-name\"=='${sl_name}'].id" --raw-output 2>/dev/null \
    | jq -r '.[]' 2>/dev/null); do
    log "  Deleting $sl_name ($SL_ID)..."
    oci network security-list delete --security-list-id "$SL_ID" --force --wait-for-state TERMINATED 2>&1 || true
  done
done

# 6. Network Security Groups (must be deleted before VCN)
log "6. Network Security Groups..."
for nsg_name in "${CLUSTER}-public-nlb-nsg" "${CLUSTER}-servers-nsg" "${CLUSTER}-workers-nsg"; do
  for NSG_ID in $(oci network nsg list --compartment-id "$COMPARTMENT" \
    --query "data[?\"display-name\"=='${nsg_name}'].id" --raw-output 2>/dev/null \
    | jq -r '.[]' 2>/dev/null); do
    for attempt in 1 2 3; do
      log "  Deleting $nsg_name ($NSG_ID)... (attempt $attempt)"
      if oci network nsg delete --nsg-id "$NSG_ID" --force 2>&1; then
        break
      fi
      log "  $nsg_name: failed (attempt $attempt), waiting 60s for VNICs to be released..."
      sleep 60
    done
  done
done

# 7. VCN (delete ALL matching VCNs — multiple can exist from previous deploys)
log "7. VCNs..."
for VCN_ID in $(oci network vcn list --compartment-id "$COMPARTMENT" \
  --query "data[?\"display-name\"=='${CLUSTER}-vcn'].id" --raw-output 2>/dev/null \
  | jq -r '.[]' 2>/dev/null); do
  log "  Deleting ${CLUSTER}-vcn ($VCN_ID)..."
  oci network vcn delete --vcn-id "$VCN_ID" --force --wait-for-state TERMINATED 2>&1 || true
done

# 8. Bastion (if any)
log "8. Bastion..."
for BASTION_ID in $(oci bastion bastion list --compartment-id "$COMPARTMENT" \
  --query "data[?contains(name, '${CLUSTER}') && \"lifecycle-state\"!='DELETED'].id" \
  --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null); do
  log "  Deleting bastion ($BASTION_ID)..."
  oci bastion bastion delete --bastion-id "$BASTION_ID" --force 2>/dev/null || true
done

# 9. IAM (dynamic group, policies, Longhorn backup service user + group)
log "9. IAM..."
for DG_ID in $(oci iam dynamic-group list --compartment-id "$COMPARTMENT" \
  --query "data[?contains(name, '${CLUSTER}') || contains(name, 'k3s')].id" \
  --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null); do
  DG_NAME=$(oci iam dynamic-group get --dynamic-group-id "$DG_ID" \
    --query 'data.name' --raw-output 2>/dev/null || echo "unknown")
  log "  Deleting dynamic group $DG_NAME ($DG_ID)..."
  oci iam dynamic-group delete --dynamic-group-id "$DG_ID" --force 2>/dev/null || true
done
for POLICY_ID in $(oci iam policy list --compartment-id "$COMPARTMENT" \
  --query "data[?contains(name, '${CLUSTER}') || contains(name, 'k3s')].id" \
  --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null); do
  POLICY_NAME=$(oci iam policy get --policy-id "$POLICY_ID" \
    --query 'data.name' --raw-output 2>/dev/null || echo "unknown")
  log "  Deleting policy $POLICY_NAME ($POLICY_ID)..."
  oci iam policy delete --policy-id "$POLICY_ID" --force 2>/dev/null || true
done

# Longhorn backup service user + group (create_longhorn_backup_user). IAM users and
# groups live in the tenancy root; exact name only — never touch other users.
SVC_NAME="${CLUSTER}-longhorn-backup"
USER_ID=$(oci iam user list --compartment-id "$TENANCY" --all \
  --query "data[?name=='${SVC_NAME}'].id | [0]" --raw-output 2>/dev/null || true)
if [ -n "$USER_ID" ] && [ "$USER_ID" != "null" ]; then
  for KEY_ID in $(oci iam customer-secret-key list --user-id "$USER_ID" \
    --query 'data[].id' --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null); do
    log "  Deleting customer secret key $KEY_ID of user $SVC_NAME..."
    oci iam customer-secret-key delete --user-id "$USER_ID" --customer-secret-key-id "$KEY_ID" --force 2>/dev/null || true
  done
  for MEMBER_GROUP_ID in $(oci iam user list-groups --user-id "$USER_ID" --all \
    --query 'data[].id' --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null); do
    oci iam group remove-user --user-id "$USER_ID" --group-id "$MEMBER_GROUP_ID" --force 2>/dev/null || true
  done
  log "  Deleting user $SVC_NAME ($USER_ID)..."
  oci iam user delete --user-id "$USER_ID" --force 2>/dev/null || true
fi
GROUP_ID=$(oci iam group list --compartment-id "$TENANCY" --all \
  --query "data[?name=='${SVC_NAME}'].id | [0]" --raw-output 2>/dev/null || true)
if [ -n "$GROUP_ID" ] && [ "$GROUP_ID" != "null" ]; then
  log "  Deleting group $SVC_NAME ($GROUP_ID)..."
  oci iam group delete --group-id "$GROUP_ID" --force 2>/dev/null || true
fi

log "OCI resource cleanup complete."
