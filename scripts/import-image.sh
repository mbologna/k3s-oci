#!/usr/bin/env bash
# import-image.sh — import the aarch64 OCI image of an os_family as a custom image
# ready for VM.Standard.A1.Flex. Prints the image OCID on stdout (everything else
# goes to stderr).
#
#   scripts/import-image.sh [--os opensuse|fcos|flatcar] [--compartment OCID]
#                           [--bucket NAME] [--keep-object]
#
#   opensuse  openSUSE Leap Immutable, the Base qcow2 of LEAP_VERSION (below)
#   fcos      Fedora CoreOS, the oraclecloud qcow2.xz of FCOS_STREAM (stable)
#   flatcar   Flatcar Container Linux, the oraclecloud qcow2 of FLATCAR_CHANNEL (stable)
#
# The OS defaults to $OS_FAMILY, then opensuse. Each download is checked against
# the checksum its publisher lists next to it, uploaded to a temporary bucket and
# imported through the REST API with launchMode CUSTOM and UEFI_64 firmware (the
# CLI can't set launch options at import time); then BIOS is removed from the
# image's firmware capability, A1.Flex compatibility added and the object deleted.
#
# The image is meant to be transient: scripts/deploy.sh deletes it once the
# instances run. Custom images are billed as Object Storage while they exist.
#
# Requires: oci CLI (configured), curl, python3, qemu-img (and xz for fcos).
set -euo pipefail

# renovate: datasource=custom.opensuse-leap depName=opensuse-leap
LEAP_VERSION="16.1"
FCOS_STREAM="${FCOS_STREAM:-stable}"
FLATCAR_CHANNEL="${FLATCAR_CHANNEL:-stable}"

OS="${OS_FAMILY:-opensuse}"
COMPARTMENT_ID="${COMPARTMENT_OCID:-}"
BUCKET_NAME="k3s-oci-image-import"
KEEP_OBJECT=false
export GODEBUG="${GODEBUG:-http2client=0}"

log() { echo "[import-image] $*" >&2; }
die() { echo "[import-image] ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --os) OS="$2"; shift 2 ;;
    --compartment) COMPARTMENT_ID="$2"; shift 2 ;;
    --bucket) BUCKET_NAME="$2"; shift 2 ;;
    --keep-object) KEEP_OBJECT=true; shift ;;
    -h | --help) sed -n '2,23p' "$0" >&2; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

for tool in oci curl python3 qemu-img; do
  command -v "$tool" >/dev/null || die "$tool not found"
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# verify <file> <algorithm> <hex digest>
verify() {
  local got
  got=$(python3 -c '
import hashlib, sys
h = hashlib.new(sys.argv[2])
with open(sys.argv[1], "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
print(h.hexdigest())' "$1" "$2")
  [[ "$got" == "$3" ]] || die "$2 of $(basename "$1") is $got, expected $3"
  log "$2 verified"
}

# ── resolve the source image ──────────────────────────────────────────────────
case "$OS" in
  opensuse)
    OS_NAME="openSUSE Leap Immutable"
    BASE="https://download.opensuse.org/distribution/leap/${LEAP_VERSION}/appliances"
    FILE=$(curl -fsSL "$BASE/" | python3 -c '
import re, sys
m = re.search(r"href=\"\./?(Leap-[0-9.]+-Immutable\.aarch64-Base-qcow-Build[^\"]+\.qcow2)\"", sys.stdin.read())
print(m.group(1) if m else "")')
    [[ -n "$FILE" ]] || die "no Immutable aarch64 Base qcow2 for Leap $LEAP_VERSION at $BASE/"
    OS_VERSION="$LEAP_VERSION"
    IMAGE_NAME="opensuse-leap-immutable-${FILE#Leap-}"
    IMAGE_NAME="${IMAGE_NAME%.qcow2}"
    log "downloading $BASE/$FILE"
    curl -fL --progress-bar -o "$TMP/src.qcow2" "$BASE/$FILE"
    verify "$TMP/src.qcow2" sha256 "$(curl -fsSL "$BASE/$FILE.sha256" | awk '{print $1}')"
    mv "$TMP/src.qcow2" "$TMP/image.qcow2"
    ;;
  fcos)
    command -v xz >/dev/null || die "xz not found"
    OS_NAME="Fedora CoreOS"
    read -r RELEASE URL SHA < <(curl -fsSL "https://builds.coreos.fedoraproject.org/streams/${FCOS_STREAM}.json" \
      | python3 -c '
import json, sys
a = json.load(sys.stdin)["architectures"]["aarch64"]["artifacts"]["oraclecloud"]
d = a["formats"]["qcow2.xz"]["disk"]
print(a["release"], d["location"], d["sha256"])') || die "no aarch64 oraclecloud image in the $FCOS_STREAM stream"
    OS_VERSION="$RELEASE"
    IMAGE_NAME="fedora-coreos-${RELEASE}-aarch64"
    log "downloading $URL"
    curl -fL --progress-bar -o "$TMP/src.qcow2.xz" "$URL"
    verify "$TMP/src.qcow2.xz" sha256 "$SHA"
    xz -d -c "$TMP/src.qcow2.xz" > "$TMP/image.qcow2"
    rm -f "$TMP/src.qcow2.xz"
    ;;
  flatcar)
    OS_NAME="Flatcar Container Linux"
    BASE="https://${FLATCAR_CHANNEL}.release.flatcar-linux.net/arm64-usr/current"
    OS_VERSION=$(curl -fsSL "$BASE/version.txt" | sed -n 's/^FLATCAR_VERSION=//p')
    [[ -n "$OS_VERSION" ]] || die "could not read the Flatcar $FLATCAR_CHANNEL version"
    IMAGE_NAME="flatcar-${FLATCAR_CHANNEL}-${OS_VERSION}-arm64"
    FILE=flatcar_production_oraclecloud_image.img
    log "downloading $BASE/$FILE (Flatcar $OS_VERSION)"
    curl -fL --progress-bar -o "$TMP/image.qcow2" "$BASE/$FILE"
    verify "$TMP/image.qcow2" sha512 "$(curl -fsSL "$BASE/$FILE.DIGESTS" | awk '/SHA512 HASH/ {getline; print $1}')"
    ;;
  *) die "--os must be opensuse, fcos or flatcar, not '$OS'" ;;
esac
qemu-img info "$TMP/image.qcow2" | grep -q 'file format: qcow2' || die "the download is not a qcow2 image"

# ── OCI context ───────────────────────────────────────────────────────────────
TENANCY_ID=$(oci iam availability-domain list --query 'data[0]."compartment-id"' --raw-output)
[[ -n "$TENANCY_ID" ]] || die "could not resolve the tenancy (oci setup config?)"
COMPARTMENT_ID="${COMPARTMENT_ID:-$TENANCY_ID}"
REGION="${OCI_REGION:-$(sed -n 's/^region *= *//p' ~/.oci/config | head -n 1)}"
[[ -n "$REGION" ]] || die "could not determine the region (set OCI_REGION)"
IAAS="https://iaas.${REGION}.oraclecloud.com/20160918"
NS=$(oci os ns get --query data --raw-output)

EXISTING=$(oci compute image list --compartment-id "$COMPARTMENT_ID" --display-name "$IMAGE_NAME" \
  --lifecycle-state AVAILABLE --query 'data[0].id' --raw-output 2>/dev/null || true)
if [[ -n "$EXISTING" && "$EXISTING" != "null" ]]; then
  log "image already imported: $EXISTING"
  echo "$EXISTING"
  exit 0
fi

# ── upload ────────────────────────────────────────────────────────────────────
OBJECT="${IMAGE_NAME}.qcow2"
if ! oci os bucket get --namespace "$NS" --bucket-name "$BUCKET_NAME" >/dev/null 2>&1; then
  oci os bucket create --compartment-id "$COMPARTMENT_ID" --namespace "$NS" --name "$BUCKET_NAME" \
    --public-access-type NoPublicAccess >/dev/null
  log "bucket $BUCKET_NAME created"
fi
log "uploading $(du -h "$TMP/image.qcow2" | cut -f1) to $BUCKET_NAME/$OBJECT"
oci os object put --namespace "$NS" --bucket-name "$BUCKET_NAME" --name "$OBJECT" \
  --file "$TMP/image.qcow2" --force >/dev/null

# ── import (UEFI_64 needs launchMode CUSTOM, REST API only) ───────────────────
BODY=$(python3 -c '
import json, sys
c, name, b, ns, obj, osname, ver = sys.argv[1:8]
print(json.dumps({
  "compartmentId": c, "displayName": name,
  "imageSourceDetails": {"sourceType": "objectStorageTuple", "bucketName": b, "namespaceName": ns,
                         "objectName": obj, "sourceImageType": "QCOW2",
                         "operatingSystem": osname, "operatingSystemVersion": ver},
  "launchMode": "CUSTOM",
  "launchOptions": {"firmware": "UEFI_64", "bootVolumeType": "PARAVIRTUALIZED",
                    "networkType": "PARAVIRTUALIZED", "remoteDataVolumeType": "PARAVIRTUALIZED"},
}))' "$COMPARTMENT_ID" "$IMAGE_NAME" "$BUCKET_NAME" "$NS" "$OBJECT" "$OS_NAME" "$OS_VERSION")
IMAGE_ID=$(oci raw-request --http-method POST --target-uri "$IAAS/images" --request-body "$BODY" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])') \
  || die "import request failed"
log "import started: $IMAGE_ID"

STATE=""
for _ in $(seq 1 60); do
  STATE=$(oci compute image get --image-id "$IMAGE_ID" --query 'data."lifecycle-state"' --raw-output)
  [[ "$STATE" == "AVAILABLE" ]] && break
  [[ "$STATE" == "IMPORTING" || "$STATE" == "PROVISIONING" ]] || die "import ended in state $STATE"
  sleep 30
done
[[ "$STATE" == "AVAILABLE" ]] || die "import still not finished after 30 minutes"
log "image available"

# ── capabilities: UEFI_64 only, and A1.Flex ───────────────────────────────────
SCHEMA_VERSION=$(oci compute global-image-capability-schema list --query 'data[0]."current-version-name"' --raw-output)
oci compute image-capability-schema create --compartment-id "$COMPARTMENT_ID" --image-id "$IMAGE_ID" \
  --global-image-capability-schema-version-name "$SCHEMA_VERSION" \
  --schema-data '{"Compute.Firmware": {"descriptorType": "enumstring", "source": "IMAGE", "values": ["UEFI_64"], "defaultValue": "UEFI_64"}}' \
  >/dev/null 2>&1 || log "WARNING: could not restrict the firmware capability to UEFI_64"
oci compute image-shape-compatibility-entry add --image-id "$IMAGE_ID" --shape-name VM.Standard.A1.Flex >/dev/null
log "capabilities set (UEFI_64 only, VM.Standard.A1.Flex)"

if [[ "$KEEP_OBJECT" == false ]]; then
  oci os object delete --namespace "$NS" --bucket-name "$BUCKET_NAME" --name "$OBJECT" --force >/dev/null
  log "uploaded object deleted"
fi

echo "$IMAGE_ID"
