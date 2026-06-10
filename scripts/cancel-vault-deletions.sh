#!/usr/bin/env bash
# Cancel PENDING_DELETION for OCI Vaults belonging to this cluster.
#
# OCI Vault has a default limit of ~5 vaults per compartment. Multiple deploys/destroys
# accumulate PENDING_DELETION entries that block new vault creation. This script cancels
# deletion to restore them to ACTIVE so a fresh tofu apply can create a new vault.
#
# After a successful deploy, old vaults can be re-scheduled for deletion manually if
# desired — or left to be cleaned up by future destroy runs.
#
# Idempotent: skips vaults that are not in PENDING_DELETION.
# Run from anywhere — requires oci CLI and COMPARTMENT_OCID env var.
set -euo pipefail

: "${COMPARTMENT_OCID:?COMPARTMENT_OCID must be set (your OCI tenancy or compartment OCID)}"
COMPARTMENT="$COMPARTMENT_OCID"
CLUSTER="${CLUSTER_NAME:-k3s-oci}"

log() { echo "[cancel-vault-deletions] $*"; }

log "Checking for ${CLUSTER} vaults in PENDING_DELETION..."

PENDING=$(oci kms management vault list \
  --compartment-id "$COMPARTMENT" \
  --query "data[?\"lifecycle-state\"=='PENDING_DELETION' && contains(\"display-name\", '${CLUSTER}')] | [].{id:id,name:\"display-name\"}" \
  --raw-output 2>/dev/null || echo "[]")

COUNT=$(echo "$PENDING" | jq 'length')
if [ "$COUNT" -eq 0 ]; then
  log "No ${CLUSTER} vaults in PENDING_DELETION. Nothing to do."
  exit 0
fi

log "Found $COUNT vault(s) in PENDING_DELETION — cancelling..."

echo "$PENDING" | jq -c '.[]' | while read -r vault; do
  VAULT_ID=$(echo "$vault" | jq -r '.id')
  NAME=$(echo "$vault" | jq -r '.name')

  log "  Cancelling deletion: $NAME ($VAULT_ID)..."
  # Do NOT pass --endpoint here: the vault's data-plane endpoint is decommissioned
  # during PENDING_DELETION. The OCI CLI control-plane routing (no --endpoint) works.
  oci kms management vault cancel-deletion \
    --vault-id "$VAULT_ID" 2>&1 | grep -E '"lifecycle-state"' || log "  Warning: cancel-deletion may have failed"
  log "  Done."
done

log "All ${CLUSTER} vault deletions cancelled. They are now ACTIVE."
log "The fresh tofu apply will create a new vault alongside these."
log "Old vaults can be re-scheduled for deletion after a successful deploy."
