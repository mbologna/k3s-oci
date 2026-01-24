#!/usr/bin/env bash
# update-repo-url.sh — replace the default mbologna/k3s-oci repoURL with your fork.
#
# Usage (run from repo root after forking):
#   bash gitops/update-repo-url.sh https://github.com/your-org/your-fork.git
#
# This updates all ArgoCD Application manifests in gitops/apps/ so they point
# to your fork instead of the upstream repo.

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
APPS_DIR="$SCRIPT_DIR/apps"

echo "Updating repoURL in $APPS_DIR ..."
find "$APPS_DIR" -name "*.yaml" -exec \
  sed -i.bak "s|$OLD_URL|$NEW_URL|g" {} \;

# Remove backup files created by sed -i on macOS
find "$APPS_DIR" -name "*.bak" -delete

echo "Done. Updated files:"
grep -rl "$NEW_URL" "$APPS_DIR"

echo ""
echo "Commit the changes:"
echo "  git add gitops/apps/ && git commit -m 'chore: update gitops repoURL to $NEW_URL'"
