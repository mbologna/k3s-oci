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
  # Use experimental channel: superset of standard, includes GRPCRoute/TCPRoute/TLSRoute
  # required by Envoy Gateway. Server-side apply avoids annotation size limit on large CRDs.
  kubectl apply --server-side --force-conflicts \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"
  echo "Gateway API CRDs ${GATEWAY_API_VERSION} (experimental channel) installed."
}

# Called by k3s-server.sh after cluster is Ready and taints are removed.

run_bootstrap() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  install_gateway_api_crds
  pre_create_secrets
  install_certmanager
  [[ "${ENABLE_EXTERNAL_SECRETS}" == "true" ]] && install_external_secrets
  install_argocd
  create_dockerhub_secret
  create_optional_apps

  # Ingress configuration waits for Gateway eg (created by gateway-config ArgoCD app,
  # which depends on envoy-gateway — see sync waves in gitops/apps/). This can take
  # up to 30 minutes on a fresh deploy. Failures are non-fatal: ArgoCD is already
  # running and the cluster is functional. To manually retry, re-run the bootstrap:
  #   cloud-init clean --logs && cloud-init init
  # Or re-invoke the individual function from cloud-init context on the first server.
  configure_grafana_ingress  || echo "WARNING: configure_grafana_ingress failed — cluster is functional; ingress can be retried via cloud-init."
  configure_longhorn_ingress || echo "WARNING: configure_longhorn_ingress failed — cluster is functional; ingress can be retried via cloud-init."
  configure_argocd_ingress   || echo "WARNING: configure_argocd_ingress failed — cluster is functional; ingress can be retried via cloud-init."

  # Longhorn backup target: applied here (alongside ingress config) because both
  # wait for ArgoCD to sync the longhorn app and CRDs to be available.
  setup_longhorn_backup_target || echo "WARNING: setup_longhorn_backup_target failed — see logs for details."

  echo "==> Bootstrap complete. ArgoCD will reconcile remaining stack via gitops/."
}
