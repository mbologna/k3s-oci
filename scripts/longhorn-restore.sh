#!/usr/bin/env bash
# Restore a rebuilt cluster's Longhorn PVCs from their newest backups.
#
# A rebuilt cluster gets empty volumes: Argo CD recreates every PVC and
# Longhorn provisions a fresh one. Each Longhorn backup records the PVC it came
# from (KubernetesStatus label: namespace, pvcName), so for every bound
# Longhorn PVC this:
#   1. finds the newest Completed backup of that namespace/name;
#   2. skips it when the PVC is already on that backup's volume, or when the
#      current volume is older than the backup (a live volume, not a fresh
#      one: never roll a running cluster back; FORCE=true overrides);
#   3. restores the backup under its old volume name (so later backups go on
#      in the same backup volume and no orphan is left), creates its PV with
#      the PVC's storage class, pre-binds it with a claimRef, deletes the empty
#      PVC and the pods using it, and hard-refreshes the owning Argo CD
#      Application, so the PVC comes back bound to the restored volume.
#
# Run it after the rebuild, once the BackupTarget is available (cloud-init
# wires it with create_longhorn_backup_user) and Argo CD has synced the apps.
# Pods using a restored PVC restart; expect a short outage per workload.
#
# Optional:
#   KUBE_CONTEXT   kubectl context of the cluster (default: the current one)
#   FORCE          (default false)  true: restore over volumes newer than the backup
#   REPLICAS       (default 2)      replicas of a restored volume (the module's default)
#   LONGHORN_PORT  (default 18080)  local port for the longhorn-frontend port-forward
# Requirements: kubectl, curl, jq
set -euo pipefail

FORCE="${FORCE:-false}"
REPLICAS="${REPLICAS:-2}"
PORT="${LONGHORN_PORT:-18080}"
API="http://localhost:$PORT/v1"

log() { echo "[longhorn-restore] $*"; }
fail() { echo "[longhorn-restore] ERROR: $*" >&2; exit 1; }
K=(kubectl)
[ -z "${KUBE_CONTEXT:-}" ] || K+=(--context "$KUBE_CONTEXT")

"${K[@]}" -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=600s >/dev/null \
  || fail "Longhorn is not ready"
available=false
for _ in $(seq 1 60); do
  available=$("${K[@]}" -n longhorn-system get backuptargets.longhorn.io default \
    -o jsonpath='{.status.available}' 2>/dev/null || true)
  [ "$available" = true ] && break
  sleep 10
done
[ "$available" = true ] || fail "the Longhorn BackupTarget 'default' is not available after 10 min"

"${K[@]}" -n longhorn-system port-forward svc/longhorn-frontend "$PORT:80" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -sf "$API/volumes" >/dev/null && break; sleep 1; done
curl -sf "$API/volumes" >/dev/null || fail "Longhorn API not reachable through the port-forward"

# Longhorn lists the backups it finds in the bucket a little after the target
# turns available.
for _ in $(seq 1 30); do
  [ "$("${K[@]}" -n longhorn-system get backups.longhorn.io --no-headers 2>/dev/null | wc -l)" -gt 0 ] && break
  sleep 10
done
BACKUPS=$("${K[@]}" -n longhorn-system get backups.longhorn.io -o json)

restored=0
while IFS=$'\t' read -r ns pvc pv sc mode; do
  newest=$(jq -c --arg ns "$ns" --arg pvc "$pvc" '
    [.items[] | select(.status.state == "Completed")
      | (.status.labels.KubernetesStatus // "{}" | fromjson) as $k
      | select($k.namespace == $ns and $k.pvcName == $pvc)
      | .status] | sort_by(.backupCreatedAt) | last // empty' <<<"$BACKUPS")
  if [ -z "$newest" ]; then
    log "$ns/$pvc: no backup, keeping the empty volume."
    continue
  fi
  old=$(jq -r .volumeName <<<"$newest")
  at=$(jq -r .backupCreatedAt <<<"$newest")
  if [ "$old" = "$pv" ]; then
    log "$ns/$pvc: already on $old."
    continue
  fi
  created=$("${K[@]}" get pv "$pv" -o jsonpath='{.metadata.creationTimestamp}')
  if [[ "$created" < "$at" ]] && [ "$FORCE" != true ]; then
    log "$ns/$pvc: $pv ($created) is older than the newest backup ($at): a live volume, skipped (FORCE=true restores anyway)."
    continue
  fi
  log "$ns/$pvc: restoring $old from the backup of $at..."
  size=$(jq -r .volumeSize <<<"$newest")
  url=$(jq -r .url <<<"$newest")
  curl -sf -X POST -H 'Content-Type: application/json' "$API/volumes" -d "$(jq -n \
    --arg n "$old" --arg s "$size" --arg u "$url" --arg m "$mode" --argjson r "$REPLICAS" \
    '{name: $n, size: $s, fromBackup: $u, numberOfReplicas: $r, accessMode: $m, frontend: "blockdev"}')" >/dev/null \
    || fail "$ns/$pvc: could not create volume $old from $url"
  state=
  for _ in $(seq 1 90); do
    state=$("${K[@]}" -n longhorn-system get volumes.longhorn.io "$old" \
      -o jsonpath='{.status.state}/{.status.restoreRequired}' 2>/dev/null || true)
    [ "$state" = detached/false ] && break
    sleep 10
  done
  [ "$state" = detached/false ] || fail "$ns/$pvc: restore of $old did not finish in 15 min ($state)"
  curl -sf -X POST -H 'Content-Type: application/json' "$API/volumes/$old?action=pvCreate" \
    -d "$(jq -n --arg n "$old" --arg sc "$sc" '{pvName: $n, fsType: "ext4", storageClassName: $sc}')" >/dev/null \
    || fail "$ns/$pvc: pvCreate for $old failed"
  for _ in $(seq 1 30); do "${K[@]}" get pv "$old" >/dev/null 2>&1 && break; sleep 2; done
  "${K[@]}" patch pv "$old" --type merge \
    -p "$(jq -nc --arg ns "$ns" --arg n "$pvc" '{spec: {claimRef: {namespace: $ns, name: $n}}}')" >/dev/null
  app=$("${K[@]}" -n "$ns" get pvc "$pvc" \
    -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' | cut -d: -f1)
  pods=$("${K[@]}" -n "$ns" get pods -o json | jq -r --arg c "$pvc" \
    '.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $c)) | .metadata.name')
  "${K[@]}" -n "$ns" delete pvc "$pvc" --wait=false >/dev/null
  # shellcheck disable=SC2086 # one pod name per word
  [ -z "$pods" ] || "${K[@]}" -n "$ns" delete pod $pods --wait=false >/dev/null
  # A PVC without an Argo CD tracking id is not recreated for you: re-apply it.
  if [ -n "$app" ]; then
    "${K[@]}" -n argocd annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  else
    log "$ns/$pvc: not managed by Argo CD: re-create the PVC (same name) to bind it to $old."
    continue
  fi
  for _ in $(seq 1 60); do
    [ "$("${K[@]}" -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}/{.status.phase}' 2>/dev/null)" = "$old/Bound" ] && break
    sleep 5
  done
  [ "$("${K[@]}" -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}' 2>/dev/null)" = "$old" ] \
    || fail "$ns/$pvc: not bound to the restored $old after 5 min (did Argo CD recreate the PVC?)"
  log "$ns/$pvc: bound to the restored $old."
  restored=$((restored + 1))
done < <("${K[@]}" get pvc -A -o json | jq -r --argjson pvs "$("${K[@]}" get pv -o json)" '
  ($pvs.items | map(select(.spec.csi.driver == "driver.longhorn.io") | {key: .metadata.name, value: true}) | from_entries) as $lh
  | .items[] | select(.status.phase == "Bound" and $lh[.spec.volumeName])
  | [.metadata.namespace, .metadata.name, .spec.volumeName, (.spec.storageClassName // "longhorn"),
     (if (.spec.accessModes // []) | index("ReadWriteMany") then "rwx" else "rwo" end)] | @tsv')

log "Restored $restored volume(s)."
