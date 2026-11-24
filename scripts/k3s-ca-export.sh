#!/usr/bin/env bash
# Export a running cluster's CA, so a rebuild keeps it and every kubeconfig
# signed by it keeps working (k3s_ca_vault_secret_id).
#
#   1. Copy server-ca.{crt,key} and client-ca.{crt,key} from the first server
#      (example/ssh-node.sh: OCI Bastion or the NLB, whichever is enabled) as a
#      base64 tar.gz, the format seed_custom_ca() in files/lib/k3s-server.sh
#      extracts before --cluster-init.
#   2. Write it to OUT_FILE (mode 600). It holds the CA private keys: keep it
#      somewhere safe, or delete it once the Vault secret exists.
#   3. With VAULT=true, create (or add a version to) the Vault secret
#      <cluster_name>-k3s-ca and print the k3s_ca_vault_secret_id line for
#      terraform.tfvars. The secret is not managed by the module, so it
#      survives `tofu destroy` and `just teardown-keep-data`; a full
#      clean-oci-resources.sh without KEEP_VAULT deletes it with the vault.
#
# Run it once, on the cluster whose CA you want to keep. Never prints key
# material: only the certificates' SHA-256 prefixes.
#
# Optional:
#   CLUSTER_NAME  (default k3s-oci)    secret name prefix
#   TF_DIR        (default ./example)  root module directory holding the state
#   OUT_FILE      (default ./<cluster_name>-k3s-ca.b64)
#   BUNDLE_FILE   an existing bundle to use instead of copying it (skips step 1)
#   VAULT         (default false)      true: store the bundle in OCI Vault
#   VAULT_OCID    (default: tofu output vault_id)
#   VAULT_KEY_ID  (default: the key of the vault's first secret)
#   COMPARTMENT_OCID (default: the vault's compartment)
#   SSH_NODE      (default example/ssh-node.sh)
# Requirements: tofu/terraform, ssh, openssl, base64, tar, gzip; oci CLI for VAULT=true
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-k3s-oci}"
TF_DIR="${TF_DIR:-$SCRIPT_DIR/../example}"
TOFU="${TOFU:-$(command -v tofu >/dev/null 2>&1 && echo tofu || echo terraform)}"
OUT_FILE="${OUT_FILE:-./${CLUSTER_NAME}-k3s-ca.b64}"
VAULT="${VAULT:-false}"
SSH_NODE="${SSH_NODE:-$SCRIPT_DIR/../example/ssh-node.sh}"
SECRET_NAME="${CLUSTER_NAME}-k3s-ca"
CA_FILES=(server-ca.crt server-ca.key client-ca.crt client-ca.key)

export GODEBUG=http2client=0

log() { echo "[k3s-ca-export] $*" >&2; }
fail() { echo "[k3s-ca-export] ERROR: $*" >&2; exit 1; }
sha() { openssl dgst -sha256 -r "$1" | cut -c1-12; }

umask 077
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── 1. Copy the CA files ──────────────────────────────────────────────────────
if [ -n "${BUNDLE_FILE:-}" ]; then
  cp "$BUNDLE_FILE" "$WORK/bundle.b64"
else
  [ -d "$TF_DIR" ] || fail "TF_DIR $TF_DIR not found"
  log "Copying ${CA_FILES[*]} from the server..."
  # ssh-node.sh reads the tofu outputs of its working directory.
  (cd "$TF_DIR" && "$SSH_NODE" server \
    "set -o pipefail; sudo tar -cf - -C /var/lib/rancher/k3s/server/tls ${CA_FILES[*]} | gzip -9n | base64 -w0") \
    >"$WORK/bundle.b64" || fail "could not copy the CA files from the server"
fi

mkdir "$WORK/ca"
base64 -d <"$WORK/bundle.b64" | tar -xzf - -C "$WORK/ca" "${CA_FILES[@]}" \
  || fail "the bundle is not a tar.gz with ${CA_FILES[*]}"
log "client-ca $(sha "$WORK/ca/client-ca.crt"), server-ca $(sha "$WORK/ca/server-ca.crt")"
for crt in client-ca server-ca; do
  openssl x509 -checkend $((365 * 86400)) -noout -in "$WORK/ca/$crt.crt" >/dev/null \
    || log "WARNING: $crt expires within a year ($(openssl x509 -enddate -noout -in "$WORK/ca/$crt.crt"))"
done

# ── 2. Write the bundle ───────────────────────────────────────────────────────
if [ "$OUT_FILE" != "${BUNDLE_FILE:-}" ]; then
  cp "$WORK/bundle.b64" "$OUT_FILE"
  chmod 600 "$OUT_FILE"
  log "Wrote $OUT_FILE: it holds the CA private keys, keep it safe."
fi

[ "$VAULT" = "true" ] || { log "Done. VAULT=true stores it in OCI Vault as $SECRET_NAME."; exit 0; }

# ── 3. Store it in OCI Vault ──────────────────────────────────────────────────
VAULT_OCID="${VAULT_OCID:-$("$TOFU" -chdir="$TF_DIR" output -raw vault_id 2>/dev/null || true)}"
[ -n "$VAULT_OCID" ] && [ "$VAULT_OCID" != "null" ] || fail "no vault: set VAULT_OCID (enable_vault must be true)"
COMPARTMENT_OCID="${COMPARTMENT_OCID:-$(oci kms management vault get --vault-id "$VAULT_OCID" \
  --query 'data."compartment-id"' --raw-output)}"
if [ -z "${VAULT_KEY_ID:-}" ]; then
  first=$(oci vault secret list -c "$COMPARTMENT_OCID" --vault-id "$VAULT_OCID" --all \
    --query 'data[0].id' --raw-output 2>/dev/null || true)
  [ -n "$first" ] && [ "$first" != "null" ] || fail "the vault has no secret to take the key from: set VAULT_KEY_ID"
  VAULT_KEY_ID=$(oci vault secret get --secret-id "$first" --query 'data."key-id"' --raw-output)
fi

# The secret's plaintext is the base64 bundle itself: fetch_from_vault decodes
# the secret bundle once, seed_custom_ca decodes the result again. The value
# goes in through a 0600 file, not the command line, where `ps` would show it.
printf '{"secretContentContent":"%s"}' "$(base64 <"$WORK/bundle.b64" | tr -d '\n')" >"$WORK/content.json"

existing=$(oci vault secret list -c "$COMPARTMENT_OCID" --vault-id "$VAULT_OCID" --all --name "$SECRET_NAME" \
  --query "data[?\"lifecycle-state\"!='DELETED'].id | [0]" --raw-output 2>/dev/null) \
  || fail "could not list the vault's secrets"
if [ -n "$existing" ] && [ "$existing" != "null" ]; then
  state=$(oci vault secret get --secret-id "$existing" --query 'data."lifecycle-state"' --raw-output)
  case "$state" in
    PENDING_DELETION | SCHEDULING_DELETION)
      log "$SECRET_NAME is $state: cancelling the deletion..."
      oci vault secret cancel-secret-deletion --secret-id "$existing" >/dev/null ;;
  esac
  oci vault secret update-base64 --secret-id "$existing" --from-json "file://$WORK/content.json" >/dev/null \
    || fail "could not update $SECRET_NAME"
  SECRET_ID="$existing"
  log "$SECRET_NAME: new version stored."
else
  SECRET_ID=$(oci vault secret create-base64 -c "$COMPARTMENT_OCID" --vault-id "$VAULT_OCID" \
    --key-id "$VAULT_KEY_ID" --secret-name "$SECRET_NAME" --from-json "file://$WORK/content.json" \
    --query 'data.id' --raw-output) || fail "could not create $SECRET_NAME"
  log "$SECRET_NAME: created."
fi

log "Add to terraform.tfvars (applies at the next --cluster-init, i.e. the next rebuild):"
echo "k3s_ca_vault_secret_id = \"$SECRET_ID\""
