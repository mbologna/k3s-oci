#!/usr/bin/env bash
# Fail when a chart that cloud-init installs with Helm (vars.tf default) and Argo CD
# then adopts (gitops targetRevision) is pinned at two different versions. Argo CD
# would move the release to its own version right after bootstrap, a downgrade
# (CRDs included) whenever the vars.tf default is the newer one. Renovate bumps
# both; this catches a PR that bumps only one.
#
# Usage: scripts/check-bootstrap-chart-versions.sh    (from anywhere in the repo)
set -euo pipefail

cd "$(dirname "$0")/.."

# vars.tf variable  gitops Application
pairs=(
  "argocd_chart_version           gitops/apps/argocd.yaml"
  "certmanager_chart_version      gitops/apps/cert-manager.yaml"
  "external_secrets_chart_version gitops/optional/external-secrets.yaml"
)

var_default() {
  awk -v name="$1" '
    $0 ~ "^variable \"" name "\"" { found = 1 }
    found && /^[[:space:]]*default[[:space:]]*=/ { gsub(/.*=[[:space:]]*"|".*/, ""); print; exit }
  ' vars.tf
}

target_revision() {
  sed -n 's/^[[:space:]]*targetRevision:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}.*/\1/p' "$1" | head -n 1
}

status=0
for pair in "${pairs[@]}"; do
  read -r var app <<<"$pair"
  bootstrap=$(var_default "$var")
  gitops=$(target_revision "$app")
  if [[ -z "$bootstrap" || -z "$gitops" ]]; then
    echo "ERROR: could not read ${var} (vars.tf: '${bootstrap}') or targetRevision (${app}: '${gitops}')" >&2
    status=1
  elif [[ "$bootstrap" != "$gitops" ]]; then
    echo "ERROR: ${var} = ${bootstrap} in vars.tf, but ${app} pins ${gitops}" >&2
    status=1
  else
    echo "ok: ${var} = ${bootstrap} (${app})"
  fi
done
exit "$status"
