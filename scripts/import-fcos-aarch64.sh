#!/usr/bin/env bash
# import-fcos-aarch64.sh — Import the current Fedora CoreOS aarch64 image for Oracle
# Cloud into an OCI tenancy as a custom image ready for VM.Standard.A1.Flex.
#
# Usage:
#   ./scripts/import-fcos-aarch64.sh [OPTIONS]
#
# Options:
#   --compartment-id OCID   Compartment OCID (default: tenancy root)
#   --region REGION         OCI region identifier (default: from ~/.oci/config)
#   --stream STREAM         FCOS stream: stable (default), testing or next
#   --bucket-name NAME      Temp Object Storage bucket (default: fcos-image-import-tmp)
#   --keep-bucket           Do not delete the temp bucket object after import
#   --image-name NAME       Display name for the imported image
#                           (default: fedora-coreos-<RELEASE>-aarch64)
#   --help                  Show this help text
#
# Prerequisites:
#   - OCI CLI installed and configured (~/.oci/config with valid key)
#   - curl, python3, xz, and ~1 GB of free space in $TMPDIR for the download
#
# What this script does:
#   1. Reads the stream's metadata for the aarch64 "oraclecloud" qcow2.xz and its SHA-256
#   2. Downloads it to a temporary file and verifies the SHA-256
#   3. Decompresses it straight into a temporary OCI Object Storage bucket
#   4. Imports it via the OCI REST API (launchMode CUSTOM, firmware UEFI_64,
#      paravirtualized boot volume and network, as scripts/import-opensuse-aarch64.sh)
#   5. Waits for the import, adds VM.Standard.A1.Flex shape compatibility, removes
#      the temporary object (unless --keep-bucket)
#
# The image records operating system "Fedora CoreOS" and the Fedora major release as
# its version, which the module filters on (fcos_version) to pick it up without
# os_image_id. Re-running the script for a build already imported (same display name)
# sets those fields on it and exits. FCOS reads Ignition, not cloud-init. The image is
# only where new nodes start: they pivot to fcos_os_version before k3s starts.

set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────────────
STREAM="stable"
BUCKET_NAME="fcos-image-import-tmp"
KEEP_BUCKET=false
COMPARTMENT_ID=""
REGION=""
IMAGE_NAME=""

# ── helpers ──────────────────────────────────────────────────────────────────
log()  { echo "  [$(date '+%H:%M:%S')] $*"; }
info() { echo ""; echo "▶ $*"; }
ok()   { echo "  ✓ $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

usage() {
  sed -n '/^# Usage:/,/^[^#]/p' "$0" | sed 's/^# \{0,2\}//'
  exit 0
}

# ── argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compartment-id) COMPARTMENT_ID="$2"; shift 2 ;;
    --region)         REGION="$2";         shift 2 ;;
    --stream)         STREAM="$2";         shift 2 ;;
    --bucket-name)    BUCKET_NAME="$2";    shift 2 ;;
    --image-name)     IMAGE_NAME="$2";     shift 2 ;;
    --keep-bucket|--no-cleanup) KEEP_BUCKET=true; shift ;;
    --help|-h)        usage ;;
    *) die "Unknown option: $1" ;;
  esac
done

case "$STREAM" in
  stable|testing|next) ;;
  *) die "--stream must be stable, testing or next, not '$STREAM'." ;;
esac

# ── prerequisites ─────────────────────────────────────────────────────────────
for cmd in oci curl python3 xz; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' not found. Install it and try again."
done

# ── resolve the image from the stream metadata ────────────────────────────────
info "Resolving the current Fedora CoreOS ${STREAM} aarch64 image for Oracle Cloud"

STREAM_JSON=$(curl -sfL "https://builds.coreos.fedoraproject.org/streams/${STREAM}.json") \
  || die "Could not download the ${STREAM} stream metadata."
read -r RELEASE XZ_URL XZ_SHA256 < <(python3 -c '
import json, sys
a = json.load(sys.stdin)["architectures"]["aarch64"]["artifacts"]["oraclecloud"]
d = a["formats"]["qcow2.xz"]["disk"]
print(a["release"], d["location"], d["sha256"])
' <<< "$STREAM_JSON") || die "No aarch64 oraclecloud qcow2.xz in the ${STREAM} stream."
FCOS_MAJOR="${RELEASE%%.*}"

[[ -z "$IMAGE_NAME" ]] && IMAGE_NAME="fedora-coreos-${RELEASE}-aarch64"
ok "Release : $RELEASE (fcos_version = \"${FCOS_MAJOR}\")"
ok "URL     : $XZ_URL"

oci iam availability-domain list --output json >/dev/null 2>&1 \
  || die "OCI CLI not configured or credentials invalid. Run 'oci setup config'."

# ── resolve tenancy / compartment / region ───────────────────────────────────
info "Resolving OCI configuration"

TENANCY_ID=$(oci iam availability-domain list \
  --query 'data[0]."compartment-id"' --raw-output 2>/dev/null)
[[ -z "$TENANCY_ID" ]] && die "Could not resolve tenancy OCID."
ok "Tenancy: $TENANCY_ID"

[[ -z "$COMPARTMENT_ID" ]] && COMPARTMENT_ID="$TENANCY_ID"
ok "Compartment: $COMPARTMENT_ID"

if [[ -z "$REGION" ]]; then
  REGION=$(grep -m1 "^region" ~/.oci/config 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ' || true)
  [[ -z "$REGION" ]] && REGION=$(oci iam region-subscription list \
    --query 'data[0]."region-name"' --raw-output 2>/dev/null || true)
fi
[[ -z "$REGION" ]] && die "Could not determine OCI region. Pass --region explicitly."
ok "Region: $REGION"

OCI_IAAS_ENDPOINT="https://iaas.${REGION}.oraclecloud.com"

# ── check for existing image ──────────────────────────────────────────────────
info "Checking for existing image '$IMAGE_NAME'"

EXISTING_ID=$(oci compute image list \
  --compartment-id "$COMPARTMENT_ID" \
  --display-name "$IMAGE_NAME" \
  --lifecycle-state AVAILABLE \
  --query 'data[0].id' --raw-output 2>/dev/null || true)

if [[ -n "$EXISTING_ID" && "$EXISTING_ID" != "None" && "$EXISTING_ID" != "null" ]]; then
  ok "Image already exists: $EXISTING_ID"
  oci compute image update \
    --image-id "$EXISTING_ID" \
    --operating-system "Fedora CoreOS" \
    --operating-system-version "$FCOS_MAJOR" \
    --force >/dev/null
  ok "Operating system set to 'Fedora CoreOS ${FCOS_MAJOR}'."
  echo ""
  echo "  Image OCID: $EXISTING_ID"
  echo "  With os_family = \"fcos\" and os_image_id unset, the module resolves it automatically."
  exit 0
fi
log "No existing image found — proceeding with import."

# ── download and verify ───────────────────────────────────────────────────────
info "Downloading and verifying the image (~800 MiB)"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
XZ_FILE="${TMP_DIR}/$(basename "$XZ_URL")"
curl -fL --progress-bar -o "$XZ_FILE" "$XZ_URL"
ACTUAL_SHA256=$(python3 -c '
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
print(h.hexdigest())
' "$XZ_FILE")
[[ "$ACTUAL_SHA256" == "$XZ_SHA256" ]] \
  || die "SHA-256 mismatch for $(basename "$XZ_FILE"): expected $XZ_SHA256, got $ACTUAL_SHA256."
ok "SHA-256 verified."

OBJECT_NAME="$(basename "$XZ_FILE" .xz)"

# ── object storage ────────────────────────────────────────────────────────────
info "Setting up OCI Object Storage"

NS=$(oci os ns get --query 'data' --raw-output 2>/dev/null)
[[ -z "$NS" ]] && die "Could not retrieve Object Storage namespace."
ok "Namespace: $NS"

if oci os bucket get --namespace "$NS" --bucket-name "$BUCKET_NAME" \
    --query 'data.name' --raw-output >/dev/null 2>&1; then
  ok "Bucket '$BUCKET_NAME' already exists."
else
  oci os bucket create \
    --compartment-id "$COMPARTMENT_ID" \
    --namespace "$NS" \
    --name "$BUCKET_NAME" \
    --public-access-type NoPublicAccess >/dev/null
  ok "Bucket '$BUCKET_NAME' created."
fi

info "Decompressing the QCOW2 into Object Storage (this may take 5–10 minutes)"

if oci os object head --namespace "$NS" --bucket-name "$BUCKET_NAME" \
    --name "$OBJECT_NAME" >/dev/null 2>&1; then
  ok "Object already present in bucket — skipping upload."
else
  xz -dc "$XZ_FILE" \
    | oci os object put \
        --namespace "$NS" \
        --bucket-name "$BUCKET_NAME" \
        --name "$OBJECT_NAME" \
        --file - \
        --force >/dev/null
  ok "Upload complete."
fi
rm -f "$XZ_FILE"

# ── import as custom image (UEFI_64 via REST API) ────────────────────────────
info "Importing custom image '$IMAGE_NAME' with UEFI_64 firmware"

# As in import-opensuse-aarch64.sh: launchOptions (firmware UEFI_64) need
# launchMode CUSTOM, which only the REST API sets at import time.
IMPORT_RESPONSE=$(oci raw-request \
  --http-method POST \
  --target-uri "${OCI_IAAS_ENDPOINT}/20160918/images" \
  --request-body "{
    \"compartmentId\": \"${COMPARTMENT_ID}\",
    \"displayName\": \"${IMAGE_NAME}\",
    \"imageSourceDetails\": {
      \"sourceType\": \"objectStorageTuple\",
      \"bucketName\": \"${BUCKET_NAME}\",
      \"namespaceName\": \"${NS}\",
      \"objectName\": \"${OBJECT_NAME}\",
      \"sourceImageType\": \"QCOW2\",
      \"operatingSystem\": \"Fedora CoreOS\",
      \"operatingSystemVersion\": \"${FCOS_MAJOR}\"
    },
    \"launchMode\": \"CUSTOM\",
    \"launchOptions\": {
      \"firmware\": \"UEFI_64\",
      \"bootVolumeType\": \"PARAVIRTUALIZED\",
      \"networkType\": \"PARAVIRTUALIZED\",
      \"remoteDataVolumeType\": \"PARAVIRTUALIZED\"
    }
  }" 2>&1)

IMAGE_ID=$(echo "$IMPORT_RESPONSE" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null || true)

[[ -z "$IMAGE_ID" || "$IMAGE_ID" == "None" ]] \
  && die "Image import request failed. Response:\n$IMPORT_RESPONSE"

ok "Import started — image OCID: $IMAGE_ID"

# ── wait for AVAILABLE ────────────────────────────────────────────────────────
info "Waiting for image import to complete (typically 5–15 minutes)"

WAITED=0
while true; do
  STATE=$(oci compute image get --image-id "$IMAGE_ID" \
    --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "UNKNOWN")
  log "State: $STATE (${WAITED}s elapsed)"
  [[ "$STATE" == "AVAILABLE" ]] && break
  [[ "$STATE" == "DELETED" || "$STATE" == "UNKNOWN" ]] \
    && die "Import failed or image was deleted (state: $STATE)."
  sleep 30
  WAITED=$(( WAITED + 30 ))
  [[ $WAITED -gt 1800 ]] && die "Timed out waiting for image import after 30 minutes."
done

ok "Image is AVAILABLE."

# ── add A1.Flex shape compatibility ──────────────────────────────────────────
info "Adding VM.Standard.A1.Flex shape compatibility"

oci compute image-shape-compatibility-entry add \
  --image-id "$IMAGE_ID" \
  --shape-name "VM.Standard.A1.Flex" >/dev/null
ok "VM.Standard.A1.Flex added."

# ── clean up object storage object ───────────────────────────────────────────
if [[ "$KEEP_BUCKET" == "false" ]]; then
  info "Cleaning up Object Storage object"
  oci os object delete \
    --namespace "$NS" \
    --bucket-name "$BUCKET_NAME" \
    --name "$OBJECT_NAME" \
    --force >/dev/null && ok "Object '$OBJECT_NAME' deleted."
else
  log "Keeping object '$OBJECT_NAME' in bucket '$BUCKET_NAME' (--keep-bucket)."
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Fedora CoreOS ${RELEASE} aarch64 — import complete"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Image OCID  : $IMAGE_ID"
echo "  Display name: $IMAGE_NAME"
echo "  SSH user    : core (keys from the instance's ssh_authorized_keys)"
echo ""
echo "  # Add to terraform.tfvars (the image is resolved automatically; no os_image_id):"
echo "  os_family    = \"fcos\""
echo "  fcos_version = \"${FCOS_MAJOR}\""
if [[ "$COMPARTMENT_ID" != "$TENANCY_ID" ]]; then
  echo "  fcos_image_compartment_ocid = \"${COMPARTMENT_ID}\""
fi
echo ""
