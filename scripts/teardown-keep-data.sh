#!/usr/bin/env bash
# Tear down a k3s-oci cluster but keep its data: the Vault (key + secrets) and the
# Object Storage buckets (etcd snapshots, Longhorn backups) survive, and are back in
# the tofu state afterwards, so the next `tofu apply` reuses them.
#
#   1. Record the import ID of every kept resource (vault, key, oci_vault_secret.*,
#      buckets, lifecycle policies) in $TF_DIR/.teardown-keep-data.tsv (no secrets).
#   2. `state rm` them, so `tofu destroy` skips them (the vault and key also have
#      prevent_destroy, which would otherwise abort the destroy).
#   3. `tofu destroy`, then $CLEAN_CMD with KEEP_VAULT/KEEP_BUCKETS exported.
#   4. Cancel any pending deletion on the vault and secrets, wait for the vault to
#      be ACTIVE, and import everything from the TSV.
#
# If step 4 fails (network, OCI throttling), fix the cause and re-run with
# IMPORT_ONLY=true: it skips steps 1-3 and replays the imports from the TSV.
#
# Required: COMPARTMENT_OCID. Optional:
#   CLUSTER_NAME  (default k3s-oci)    passed to CLEAN_CMD
#   TF_DIR        (default ./example)  root module directory holding the state
#   TOFU          (default tofu, else terraform)
#   CLEAN_CMD     (default scripts/clean-oci-resources.sh) — a wrapper may add
#                 its own cleanup (e.g. Tailscale devices) and call the module script
#   IMPORT_ONLY   (default false)
# Requirements: tofu/terraform, oci CLI, jq
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPARTMENT_OCID="${COMPARTMENT_OCID:?COMPARTMENT_OCID is required}"
CLUSTER_NAME="${CLUSTER_NAME:-k3s-oci}"
TF_DIR="${TF_DIR:-$SCRIPT_DIR/../example}"
TOFU="${TOFU:-$(command -v tofu >/dev/null 2>&1 && echo tofu || echo terraform)}"
CLEAN_CMD="${CLEAN_CMD:-bash $SCRIPT_DIR/clean-oci-resources.sh}"
IMPORT_ONLY="${IMPORT_ONLY:-false}"
TSV="$TF_DIR/.teardown-keep-data.tsv"

# OCI Go SDK has a TLS/HTTP2 bug — GODEBUG=http2client=0 is required for all tofu operations.
export GODEBUG=http2client=0

log() { echo "[teardown-keep-data] $*"; }
tf() { "$TOFU" -chdir="$TF_DIR" "$@"; }

[ -d "$TF_DIR" ] || { echo "ERROR: TF_DIR $TF_DIR not found" >&2; exit 1; }

if [ "$IMPORT_ONLY" != "true" ]; then
  log "Initialising $TF_DIR..."
  tf init -input=false >/dev/null

  # ── 1. Record kept resources ────────────────────────────────────────────────
  # Columns: address, import ID. The key's import ID is managementEndpoint/<url>/keys/<ocid>, not the bare OCID.
  log "Recording kept resources in $TSV..."
  tf show -json | jq -r '
    [.values.root_module | .. | objects | select(.mode? == "managed")]
    | map(select(.type | test("^oci_(kms_vault|kms_key|vault_secret|objectstorage_bucket|objectstorage_object_lifecycle_policy)$")))
    | .[]
    | if .type == "oci_kms_key" then [.address, "managementEndpoint/\(.values.management_endpoint)/keys/\(.values.id)"]
      else [.address, .values.id] end
    | @tsv' >"$TSV.new"
  if [ ! -s "$TSV.new" ]; then
    rm -f "$TSV.new"
    echo "ERROR: no vault or bucket resources in state — nothing to keep. Use 'tofu destroy' + clean-oci-resources.sh instead." >&2
    exit 1
  fi
  mv "$TSV.new" "$TSV"
  cut -f1 "$TSV" | sed 's/^/  /'

  # ── 2. Remove them from state ───────────────────────────────────────────────
  log "Removing kept resources from state..."
  while IFS=$'\t' read -r address _; do
    tf state rm "$address" >/dev/null
  done <"$TSV"

  # ── 3. Destroy + clean ──────────────────────────────────────────────────────
  log "Running $TOFU destroy..."
  tf destroy -auto-approve

  log "Cleaning leftover OCI resources ($CLEAN_CMD)..."
  # shellcheck disable=SC2086  # CLEAN_CMD is a command line, word splitting intended
  COMPARTMENT_OCID="$COMPARTMENT_OCID" CLUSTER_NAME="$CLUSTER_NAME" \
    KEEP_VAULT=true KEEP_BUCKETS=true $CLEAN_CMD
fi

[ -s "$TSV" ] || { echo "ERROR: $TSV missing — nothing to import" >&2; exit 1; }

# ── 4. Cancel pending deletions + re-import ─────────────────────────────────────
vault_state() {
  oci kms management vault get --vault-id "$1" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo UNKNOWN
}

VAULT_ID=$(awk -F'\t' '$1 ~ /oci_kms_vault\./ {print $2; exit}' "$TSV")
if [ -n "$VAULT_ID" ]; then
  state=$(vault_state "$VAULT_ID")
  case "$state" in
    SCHEDULING_DELETION | PENDING_DELETION)
      log "Vault is $state — cancelling deletion..."
      oci kms management vault cancel-deletion --vault-id "$VAULT_ID" >/dev/null ;;
  esac
  for _ in $(seq 1 60); do
    state=$(vault_state "$VAULT_ID")
    [ "$state" = ACTIVE ] && break
    sleep 10
  done
  [ "$state" = ACTIVE ] || { echo "ERROR: vault still $state after 10 min — re-run with IMPORT_ONLY=true" >&2; exit 1; }
  log "Vault is ACTIVE."
fi

failed=0
while IFS=$'\t' read -r address id; do
  if [[ "$address" == *oci_vault_secret.* ]]; then
    state=$(oci vault secret get --secret-id "$id" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo UNKNOWN)
    case "$state" in
      SCHEDULING_DELETION | PENDING_DELETION)
        oci vault secret cancel-secret-deletion --secret-id "$id" >/dev/null || true ;;
    esac
  fi
  if tf state list "$address" 2>/dev/null | grep -qxF "$address"; then
    log "  $address: already in state"
  elif tf import -input=false "$address" "$id" >/dev/null 2>&1; then
    log "  $address: imported"
  else
    log "  WARNING: $address: import failed (id $id)"
    failed=1
  fi
done <"$TSV"

if [ "$failed" -ne 0 ]; then
  echo "ERROR: some imports failed — fix the cause, then re-run with IMPORT_ONLY=true" >&2
  exit 1
fi
rm -f "$TSV"
log "Teardown complete; vault and buckets kept and back in state."
log "Rebuild with: $TOFU -chdir=$TF_DIR apply"
log "Note: the new server will log a 'previous etcd snapshots exist' warning — expected, see README (Rebuild keeping data)."
