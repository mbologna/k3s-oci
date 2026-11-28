#!/usr/bin/env bash
# Validate every manifest under gitops/ against the Kubernetes and CRD schemas with
# kubeconform. Each YAML file is checked on its own (templates included), and each
# kustomization is built and checked as a whole, remote resources too.
#
# CRD schemas come from the datreeio CRDs-catalog. Resources it has no schema for are
# skipped, not failed. --strict rejects unknown fields, the usual typo symptom.
#
# Usage: scripts/validate-gitops.sh            (from the repo root; needs kubeconform, kustomize)
set -euo pipefail

cd "$(dirname "$0")/.."

CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
KUBECONFORM=(kubeconform -strict -summary -ignore-missing-schemas
  -schema-location default -schema-location "$CRD_SCHEMAS")

echo "== manifest files"
find gitops -name '*.yaml' ! -name kustomization.yaml -print0 | sort -z | xargs -0 "${KUBECONFORM[@]}"

while IFS= read -r kustomization; do
  dir=$(dirname "$kustomization")
  echo "== kustomize build ${dir}"
  kustomize build "$dir" | "${KUBECONFORM[@]}" -
done < <(find gitops -name kustomization.yaml | sort)
