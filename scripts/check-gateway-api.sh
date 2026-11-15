#!/usr/bin/env bash
# The Gateway API CRDs installed at bootstrap (gateway_api_version, vars.tf) must
# be the minor Envoy Gateway bundles: its chart re-applies its own CRDs
# (sigs.k8s.io/gateway-api in envoyproxy/gateway's go.mod) at every sync, so a
# different minor at bootstrap only means two CRD versions fighting. Fails when
# an Envoy Gateway bump brings another Gateway API minor: set gateway_api_version
# to that minor's latest patch in the same PR.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
envoy=$(sed -nE 's/^ *targetRevision: *"?(v[0-9.]+)"?.*/\1/p' "$root/gitops/apps/envoy-gateway.yaml" | head -1)
ours=$(awk '/variable "gateway_api_version"/,/^}/' "$root/vars.tf" | sed -nE 's/^ *default *= *"(v[0-9.]+)".*/\1/p')
[[ -n $envoy && -n $ours ]] || { echo "could not read the Envoy Gateway or Gateway API pin" >&2; exit 1; }
bundled=$(curl -fsSL "https://raw.githubusercontent.com/envoyproxy/gateway/${envoy}/go.mod" |
  sed -nE 's#^[[:space:]]*sigs\.k8s\.io/gateway-api (v[0-9.]+).*#\1#p' | head -1)
[[ -n $bundled ]] || { echo "Envoy Gateway ${envoy}: no sigs.k8s.io/gateway-api in its go.mod" >&2; exit 1; }
minor() { local v=${1#v}; echo "${v%.*}"; }
if [[ $(minor "$ours") != "$(minor "$bundled")" ]]; then
  echo "gateway_api_version ${ours} is not the Gateway API minor Envoy Gateway ${envoy} bundles (${bundled})" >&2
  exit 1
fi
echo "Gateway API ${ours} matches Envoy Gateway ${envoy}'s bundled ${bundled} (same minor)"
