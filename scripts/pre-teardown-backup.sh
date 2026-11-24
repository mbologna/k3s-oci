#!/usr/bin/env bash
# Take fresh backups of a running cluster right before a teardown, so the
# rebuild restores minutes-old data instead of the last scheduled run:
#   1. an etcd snapshot, uploaded to <cluster_name>-terraform-state by the
#      server's own /usr/local/bin/etcd-snapshot-upload.sh;
#   2. a Longhorn backup of every volume in the `default` group (the group
#      cloud-init's daily-backup RecurringJob covers), through a temporary
#      RecurringJob that is deleted once every volume has a Completed backup
#      newer than the start of this run. scripts/longhorn-restore.sh restores
#      the newest backup per PVC, so these are the ones the rebuild uses.
# Exits non-zero when either fails, so a caller (teardown-keep-data.sh with
# PRE_BACKUP=true) does not tear down.
#
# Optional:
#   TF_DIR        (default ./example)  root module directory holding the state
#   SSH_NODE      (default example/ssh-node.sh)
#   KUBE_CONTEXT  kubectl context of the cluster (default: the current one)
#   SKIP_ETCD     (default false)      true: Longhorn backups only
#   TIMEOUT_MIN   (default 15)         how long to wait for the Longhorn backups
# Requirements: kubectl, jq, ssh (through example/ssh-node.sh), tofu/terraform
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${TF_DIR:-$SCRIPT_DIR/../example}"
SSH_NODE="${SSH_NODE:-$SCRIPT_DIR/../example/ssh-node.sh}"
SKIP_ETCD="${SKIP_ETCD:-false}"
TIMEOUT_MIN="${TIMEOUT_MIN:-15}"
JOB=pre-teardown-backup

export GODEBUG=http2client=0

log() { echo "[pre-teardown-backup] $*"; }
fail() { echo "[pre-teardown-backup] ERROR: $*" >&2; exit 1; }
K=(kubectl)
[ -z "${KUBE_CONTEXT:-}" ] || K+=(--context "$KUBE_CONTEXT")
LH=(-n longhorn-system)

# ── 1. etcd snapshot ──────────────────────────────────────────────────────────
if [ "$SKIP_ETCD" != "true" ]; then
  [ -d "$TF_DIR" ] || fail "TF_DIR $TF_DIR not found"
  log "Uploading a fresh etcd snapshot from the server..."
  (cd "$TF_DIR" && "$SSH_NODE" server sudo /usr/local/bin/etcd-snapshot-upload.sh) >/dev/null \
    || fail "etcd snapshot upload failed: check /var/log/etcd-snapshot-upload.log on the server"
  log "etcd snapshot uploaded."
fi

# ── 2. Longhorn backups ───────────────────────────────────────────────────────
[ "$("${K[@]}" "${LH[@]}" get backuptargets.longhorn.io default -o jsonpath='{.status.available}' 2>/dev/null)" = true ] \
  || fail "the Longhorn BackupTarget 'default' is not available: backups would fail"

volumes=$("${K[@]}" "${LH[@]}" get volumes.longhorn.io -o jsonpath='{.items[*].metadata.name}')
if [ -z "$volumes" ]; then
  log "No Longhorn volumes: nothing to back up."
  exit 0
fi

# A RecurringJob only takes a cron: fire two minutes from now.
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
minute=$(( (10#$(date -u +%M) + 2) % 60 ))
trap '"${K[@]}" "${LH[@]}" delete recurringjob "$JOB" --ignore-not-found >/dev/null' EXIT
log "Backing up $(wc -w <<<"$volumes" | tr -d ' ') Longhorn volume(s) through a temporary RecurringJob..."
"${K[@]}" apply -f - >/dev/null <<EOF
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: $JOB
  namespace: longhorn-system
spec:
  task: backup
  cron: "$minute * * * *"
  groups:
    - default
  # retain counts only this job's backups; daily-backup keeps its own.
  retain: 1
  concurrency: 2
EOF

missing=0
for _ in $(seq 1 $((TIMEOUT_MIN * 6))); do
  backups=$("${K[@]}" "${LH[@]}" get backups.longhorn.io -o json)
  missing=0
  for v in $volumes; do
    fresh=$(jq --arg v "$v" --arg s "$since" '[.items[] | select(.status.volumeName == $v
        and .status.state == "Completed" and (.status.backupCreatedAt // "") >= $s)] | length' <<<"$backups")
    [ "$fresh" -gt 0 ] || missing=$((missing + 1))
  done
  [ "$missing" -eq 0 ] && break
  sleep 10
done
[ "$missing" -eq 0 ] \
  || fail "$missing volume(s) have no backup newer than $since after $TIMEOUT_MIN min (volumes outside the default group are never backed up): don't tear down"
log "Every volume has a backup from this run."
