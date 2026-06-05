#!/usr/bin/env bash
# lib/k3s-bootstrap.sh -- first-server bootstrap orchestrator.
# Called by k3s-server.sh via run_bootstrap() after the cluster is Ready.
# Functions are defined in the preceding lib scripts (concatenated by cloud-init):
#   k3s-secrets.sh        -> pre_create_secrets()
#   k3s-cert-manager.sh   -> install_certmanager()
#   k3s-external-secrets.sh -> install_external_secrets()
#   k3s-argocd.sh         -> install_argocd(), create_dockerhub_secret(),
#                            create_optional_apps(), configure_grafana_ingress()
# Pure bash -- no Terraform interpolation.
#
# What is NOT here (managed by ArgoCD via gitops/apps/):
#   - Envoy Gateway Helm install  -> gitops/apps/envoy-gateway.yaml
#   - Gateway resources (EnvoyProxy, GatewayClass, Gateway, redirect, TLS policy)
#                                 -> gitops/gateway/
#   - Longhorn Helm install       -> gitops/apps/longhorn.yaml
#   - kured Helm install          -> gitops/apps/kured.yaml
#   - system-upgrade-controller   -> gitops/apps/system-upgrade-controller.yaml
#   - external-dns Helm install   -> gitops/apps/external-dns.yaml
#
# shellcheck disable=SC2154

# -- Gateway API CRDs ----------------------------------------------------------
# Install before ArgoCD syncs envoy-gateway and gateway-config apps.
# The Envoy Gateway Helm chart does not bundle these upstream CRDs.

install_gateway_api_crds() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  # Use experimental channel: superset of standard, includes GRPCRoute/TCPRoute/TLSRoute
  # required by Envoy Gateway. Server-side apply avoids annotation size limit on large CRDs.
  kubectl apply --server-side --force-conflicts \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"
  echo "Gateway API CRDs ${GATEWAY_API_VERSION} (experimental channel) installed."
}

# Called by k3s-server.sh after cluster is Ready and taints are removed.

run_bootstrap() {
  install_gateway_api_crds
  pre_create_secrets
  install_certmanager
  [[ "${ENABLE_EXTERNAL_SECRETS}" == "true" ]] && install_external_secrets
  install_argocd
  create_dockerhub_secret
  create_optional_apps
  configure_grafana_ingress || { echo "ERROR: configure_grafana_ingress failed — aborting bootstrap."; exit 1; }
  configure_longhorn_ingress || { echo "ERROR: configure_longhorn_ingress failed — aborting bootstrap."; exit 1; }
  configure_argocd_ingress   || { echo "ERROR: configure_argocd_ingress failed — aborting bootstrap."; exit 1; }
  echo "==> Bootstrap complete. ArgoCD will reconcile remaining stack via gitops/."
}
