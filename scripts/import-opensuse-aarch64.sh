#!/usr/bin/env bash
# import-opensuse-aarch64.sh — Import the latest openSUSE Leap Minimal VM Cloud
# aarch64 image into an OCI tenancy as a custom image ready for VM.Standard.A1.Flex.
#
# Usage:
#   ./scripts/import-opensuse-aarch64.sh [OPTIONS]
#
# Options:
#   --compartment-id OCID   Compartment OCID (default: tenancy root)
#   --region REGION         OCI region identifier (default: from ~/.oci/config)
#   --leap-version VERSION  openSUSE Leap version (default: 16.0)
#   --bucket-name NAME      Temp Object Storage bucket (default: opensuse-image-import-tmp)
#   --keep-bucket           Do not delete the temp bucket object after import
#   --no-cleanup            Alias for --keep-bucket
#   --image-name NAME       Display name for the imported image
#                           (default: openSUSE-Leap-<VERSION>-Minimal-aarch64)
#   --help                  Show this help text
#
# Prerequisites:
#   - OCI CLI installed and configured (~/.oci/config with valid key)
#   - curl, python3 (standard on macOS and most Linux distros)
#
# What this script does:
#   1. Resolves the latest openSUSE Leap Minimal VM Cloud aarch64 QCOW2 URL
#   2. Creates a temporary OCI Object Storage bucket (idempotent)
#   3. Streams the QCOW2 directly into the bucket (no local disk required)
#   4. Imports the image via the OCI REST API with:
#        launchMode   = CUSTOM
#        firmware     = UEFI_64        (required for VM.Standard.A1.Flex / aarch64)
#        bootVolume   = PARAVIRTUALIZED
#        networkType  = PARAVIRTUALIZED
#   5. Waits for the import to complete (polls every 30 s)
#   6. Adds VM.Standard.A1.Flex shape compatibility
#   7. Removes the QCOW2 object from the temp bucket (unless --keep-bucket)
#   8. Prints the image OCID and SSH user-data hint
#
# Known caveats for openSUSE on OCI (verified with Leap 16.0):
#   - SSH key injection: the openSUSE cloud image's cloud-init does NOT read keys
#     from OCI's --metadata field by default. Always pass --user-data-file with a
#     #cloud-config that sets ssh_authorized_keys explicitly (example shown at end).
#   - Oracle Cloud Agent (OCA): unavailable on custom images — no OCI-native
#     monitoring or patch management.
#   - This module's cloud-init scripts are Ubuntu-specific (apt, unattended-upgrades).
#     Using the imported image with os_image_id requires a custom fork.

set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────────────
LEAP_VERSION="16.0"
BUCKET_NAME="opensuse-image-import-tmp"
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
    --leap-version)   LEAP_VERSION="$2";   shift 2 ;;
    --bucket-name)    BUCKET_NAME="$2";    shift 2 ;;
    --image-name)     IMAGE_NAME="$2";     shift 2 ;;
    --keep-bucket|--no-cleanup) KEEP_BUCKET=true; shift ;;
    --help|-h)        usage ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -z "$IMAGE_NAME" ]] && IMAGE_NAME="openSUSE-Leap-${LEAP_VERSION}-Minimal-aarch64"

# ── prerequisites ─────────────────────────────────────────────────────────────
for cmd in oci curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' not found. Install it and try again."
done

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
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "  Image OCID : $EXISTING_ID"
  echo "  SSH user   : opensuse"
  echo "  Launch hint: see end of this output"
  print_launch_hint "$EXISTING_ID"
  exit 0
fi
log "No existing image found — proceeding with import."

# ── resolve latest qcow2 URL ─────────────────────────────────────────────────
info "Resolving latest openSUSE Leap ${LEAP_VERSION} Minimal VM Cloud aarch64 QCOW2"

BASE_URL="https://download.opensuse.org/distribution/leap/${LEAP_VERSION}/appliances"
# Prefer the versioned build filename (e.g. Leap-16.0-Minimal-VM.aarch64-Cloud-Build16.2.qcow2)
# Fall back to the symlink (Leap-16.0-Minimal-VM.aarch64-Cloud.qcow2)
QCOW2_FILE=$(curl -sL "${BASE_URL}/" \
  | python3 -c "
import sys, re
content = sys.stdin.read()
# versioned build first (more specific), then plain symlink
# links on the page are prefixed with './' — strip it
for pat in [
  r'href=\"\./?(Leap-[0-9.]+-Minimal-VM\.aarch64-Cloud-Build[^\"]+\.qcow2)\"',
  r'href=\"\./?(Leap-[0-9.]+-Minimal-VM\.aarch64-Cloud\.qcow2)\"',
]:
    m = re.search(pat, content)
    if m:
        print(m.group(1))
        break
" 2>/dev/null || true)

[[ -z "$QCOW2_FILE" ]] \
  && die "Could not find Minimal VM Cloud aarch64 QCOW2 for Leap ${LEAP_VERSION} at ${BASE_URL}/"

QCOW2_URL="${BASE_URL}/${QCOW2_FILE}"
QCOW2_SIZE=$(curl -sIL "$QCOW2_URL" | grep -i "^content-length:" | tail -1 | awk '{print $2}' | tr -d '\r')
QCOW2_SIZE_MiB=$(( ${QCOW2_SIZE:-0} / 1024 / 1024 ))

ok "File    : $QCOW2_FILE"
ok "URL     : $QCOW2_URL"
ok "Size    : ~${QCOW2_SIZE_MiB} MiB"

OBJECT_NAME="$QCOW2_FILE"

# ── object storage namespace ─────────────────────────────────────────────────
info "Setting up OCI Object Storage"

NS=$(oci os ns get --query 'data' --raw-output 2>/dev/null)
[[ -z "$NS" ]] && die "Could not retrieve Object Storage namespace."
ok "Namespace: $NS"

# Create bucket if it doesn't exist
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

# ── upload qcow2 (stream — no local disk required) ────────────────────────────
info "Streaming QCOW2 to OCI Object Storage (this may take 2–5 minutes)"

if oci os object head --namespace "$NS" --bucket-name "$BUCKET_NAME" \
    --name "$OBJECT_NAME" >/dev/null 2>&1; then
  ok "Object already present in bucket — skipping upload."
else
  curl -L --progress-bar "$QCOW2_URL" \
    | oci os object put \
        --namespace "$NS" \
        --bucket-name "$BUCKET_NAME" \
        --name "$OBJECT_NAME" \
        --file - \
        --force >/dev/null
  ok "Upload complete."
fi

# ── import as custom image (UEFI_64 via REST API) ────────────────────────────
info "Importing custom image '$IMAGE_NAME' with UEFI_64 firmware"

# OCI CLI import only supports BIOS by default; launchOptions (including
# firmware=UEFI_64) require launchMode=CUSTOM, which is only settable via the
# REST API at import time — not via `oci compute image import` CLI.
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
      \"sourceImageType\": \"QCOW2\"
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
info "Waiting for image import to complete (typically 3–8 minutes)"

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
  [[ $WAITED -gt 900 ]] && die "Timed out waiting for image import after 15 minutes."
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
echo "  openSUSE Leap ${LEAP_VERSION} Minimal aarch64 — import complete"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Image OCID  : $IMAGE_ID"
echo "  Display name: $IMAGE_NAME"
echo "  Firmware    : UEFI_64  (required for VM.Standard.A1.Flex)"
echo "  Shape compat: VM.Standard.A1.Flex"
echo "  SSH user    : opensuse"
echo ""
echo "  ── Launch example (OCI CLI) ──────────────────────────────────────"
echo ""
echo "  # Create a minimal cloud-config to inject your SSH public key."
echo "  # The openSUSE cloud image does NOT read SSH keys from --metadata;"
echo "  # --user-data-file is required."
echo ""
echo "  cat > /tmp/cloud-config.yaml << 'EOF'"
echo "  #cloud-config"
echo "  users:"
echo "    - name: opensuse"
echo "      sudo: ['ALL=(ALL) NOPASSWD:ALL']"
echo "      groups: wheel"
echo "      shell: /bin/bash"
echo "      ssh_authorized_keys:"
echo "        - \$(cat ~/.ssh/id_rsa.pub)"
echo "  EOF"
echo ""
echo "  oci compute instance launch \\"
echo "    --compartment-id ${COMPARTMENT_ID} \\"
echo "    --availability-domain <YOUR_AD> \\"
echo "    --shape VM.Standard.A1.Flex \\"
echo "    --shape-config '{\"ocpus\":1,\"memoryInGBs\":6}' \\"
echo "    --image-id ${IMAGE_ID} \\"
echo "    --subnet-id <YOUR_SUBNET_OCID> \\"
echo "    --assign-public-ip true \\"
echo "    --display-name opensuse-leap-${LEAP_VERSION} \\"
echo "    --user-data-file /tmp/cloud-config.yaml \\"
echo "    --boot-volume-size-in-gbs 50"
echo ""
echo "  ── Use with this Terraform module ───────────────────────────────"
echo ""
echo "  # Add to terraform.tfvars:"
echo "  os_image_id = \"${IMAGE_ID}\""
echo "  # NOTE: cloud-init scripts in this module are Ubuntu-specific."
echo "  # A custom fork is required to use openSUSE with the full stack."
echo ""
