#!/usr/bin/env bash
# deploy.sh — build a cluster end to end:
#   1. import the image of OS_FAMILY (scripts/import-image.sh) and record its OCID
#      in $TF_DIR/k3s-image.auto.tfvars (later plans need a value; the instances
#      ignore it once they exist);
#   2. tofu apply; the nodes install k3s and the first one Argo CD on their own;
#   3. delete the custom image once every node is RUNNING (instances keep their
#      boot volumes);
#   4. open the Bastion port forward (scripts/tunnel.sh up), write the kubeconfig
#      output to $KUBECONFIG_OUT and wait until every server is Ready.
#
#   OS_FAMILY=opensuse TF_DIR=example scripts/deploy.sh
#
# Env: OS_FAMILY (must match the root module's os_family; default opensuse),
# TF_DIR (default ../example), KUBECONFIG_OUT (default ~/.kube/k3s-oci-<cluster>),
# KEEP_IMAGE=true to keep the image. The tofu backend and variables come from TF_DIR.
# Requires: tofu, oci CLI, kubectl, qemu-img, curl, python3, ssh (xz for fcos).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${TF_DIR:-$SCRIPT_DIR/../example}"
export TF_DIR OS_FAMILY="${OS_FAMILY:-opensuse}" GODEBUG="${GODEBUG:-http2client=0}"

log() { echo "[deploy] $*" >&2; }
die() { echo "[deploy] ERROR: $*" >&2; exit 1; }
tf() { tofu -chdir="$TF_DIR" "$@"; }

for tool in tofu oci kubectl qemu-img curl python3 ssh; do
  command -v "$tool" >/dev/null || die "$tool not found"
done

# ── 1. image ──────────────────────────────────────────────────────────────────
IMAGE_ID=$("$SCRIPT_DIR/import-image.sh" --os "$OS_FAMILY")
printf '# Written by scripts/deploy.sh: the image the nodes were created from\n# (deleted after the deploy; the instances ignore later changes).\nimage_id = "%s"\n' \
  "$IMAGE_ID" > "$TF_DIR/k3s-image.auto.tfvars"
log "image $IMAGE_ID"

# ── 2. apply ──────────────────────────────────────────────────────────────────
tf init -input=false >/dev/null
tf apply -input=false -auto-approve
[[ "$(tf output -raw os_family)" == "$OS_FAMILY" ]] || die "OS_FAMILY=$OS_FAMILY, but the module's os_family is $(tf output -raw os_family)"

# ── 3. delete the image ───────────────────────────────────────────────────────
if [[ "${KEEP_IMAGE:-false}" != true ]]; then
  for id in $(tf output -json node_instance_ids | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).values()))'); do
    # `instance get` has no --wait-for-state (only the action commands do).
    for _ in $(seq 1 120); do
      [[ "$(oci compute instance get --instance-id "$id" --query 'data."lifecycle-state"' --raw-output)" == RUNNING ]] && break
      sleep 10
    done
  done
  oci compute image delete --image-id "$IMAGE_ID" --force >/dev/null
  log "custom image deleted"
fi

# ── 4. access ─────────────────────────────────────────────────────────────────
KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/.kube/k3s-oci-$(tf output -raw cluster_name)}"
mkdir -p "$(dirname "$KUBECONFIG_OUT")"
(umask 077 && tf output -raw kubeconfig > "$KUBECONFIG_OUT")
"$SCRIPT_DIR/tunnel.sh" up
export KUBECONFIG="$KUBECONFIG_OUT"

# The nodes bootstrap on their own: an image-based OS reboots once into its
# staged packages (opensuse, fcos) or into the cluster's release (fcos), so the
# API can take 10-20 minutes.
NODES=$(tf output -json node_private_ips | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
log "waiting for $NODES Ready servers"
for _ in $(seq 1 180); do
  ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l | tr -d ' ')
  [[ "$ready" -ge "$NODES" ]] && break
  sleep 10
done
kubectl get nodes -o wide
[[ "${ready:-0}" -ge "$NODES" ]] || die "only ${ready:-0} of $NODES servers Ready after 30 minutes (node logs: /var/log/k3s-oci-bootstrap.log, scripts/tunnel.sh ssh <node>)"

log "done. kubeconfig: $KUBECONFIG_OUT (through scripts/tunnel.sh up). Argo CD syncs gitops_repo_url from here."
