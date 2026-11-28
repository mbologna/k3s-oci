#!/usr/bin/env bash
# update-repo-url.sh — replace the default mbologna/k3s-oci repoURL with your fork.
#
# Usage (run from repo root after forking):
#   bash gitops/update-repo-url.sh https://github.com/your-org/your-fork.git
#
# This updates every ArgoCD Application manifest under gitops/ (apps/, optional/
# and the */application-template.yaml files) so they point to your fork instead
# of the upstream repo.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <your-repo-url>" >&2
  echo "  Example: $0 https://github.com/myorg/k3s-oci.git" >&2
  exit 1
fi

NEW_URL="$1"
OLD_URL="https://github.com/mbologna/k3s-oci.git"

if [[ "$NEW_URL" == "$OLD_URL" ]]; then
  echo "URL is already $OLD_URL — nothing to do."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mapfile -t FILES < <(grep -rlF --include='*.yaml' "$OLD_URL" "$SCRIPT_DIR" || true)
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No manifests reference $OLD_URL — nothing to do."
  exit 0
fi

for f in "${FILES[@]}"; do
  sed -i.bak "s|$OLD_URL|$NEW_URL|g" "$f"
  rm -f "$f.bak"
done

echo "Done. Updated files:"
printf '  %s\n' "${FILES[@]#"$SCRIPT_DIR"/}"

echo ""
echo "Commit the changes:"
echo "  git add gitops/ && git commit -m 'chore: update gitops repoURL to $NEW_URL'"
