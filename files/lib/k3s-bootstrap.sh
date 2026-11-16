#!/usr/bin/env bash
# lib/k3s-bootstrap.sh -- first-server bootstrap orchestrator.
# Called by k3s-server.sh via run_bootstrap() after the cluster is Ready.
# Functions are defined in the preceding lib scripts (concatenated by cloud-init):
#   k3s-secrets.sh        -> pre_create_secrets()
#   k3s-cert-manager.sh   -> install_certmanager()
#   k3s-external-secrets.sh -> install_external_secrets()
#   k3s-argocd.sh         -> install_argocd(), create_dockerhub_secret(),
#                            create_optional_apps()
# Pure bash -- no Terraform interpolation.
#
# What is NOT here (managed by ArgoCD via gitops/apps/):
#   - Traefik Helm install (ingress, HTTP->HTTPS redirect, TLS options)
#                                 -> gitops/apps/traefik.yaml
#   - Longhorn Helm install       -> gitops/apps/longhorn.yaml
#   - kured Helm install          -> gitops/apps/kured.yaml
#   - system-upgrade-controller   -> gitops/apps/system-upgrade-controller.yaml
#   - external-dns Helm install   -> Application created by create_external_dns_app()
#
# shellcheck disable=SC2154

# Called by k3s-server.sh after cluster is Ready and taints are removed.

run_bootstrap() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  pre_create_secrets
  install_certmanager
  [[ "${ENABLE_EXTERNAL_SECRETS}" == "true" ]] && install_external_secrets
  install_argocd
  create_dockerhub_secret
  create_optional_apps

  # Ingress configuration waits for the traefik IngressClass (the traefik ArgoCD
  # app, sync wave 1 in gitops/apps/). This can take up to 30 minutes on a fresh
  # deploy. Failures are non-fatal: ArgoCD is already
  # running and the cluster is functional. To manually retry, re-run the bootstrap:
  #   cloud-init clean --logs && cloud-init init
  # Or re-invoke the individual function from cloud-init context on the first server.
  configure_longhorn_ingress || echo "WARNING: configure_longhorn_ingress failed — cluster is functional; ingress can be retried via cloud-init."
  configure_argocd_ingress   || echo "WARNING: configure_argocd_ingress failed — cluster is functional; ingress can be retried via cloud-init."

  # Longhorn backup target: applied here (alongside ingress config) because both
  # wait for ArgoCD to sync the longhorn app and CRDs to be available.
  setup_longhorn_backup_target || echo "WARNING: setup_longhorn_backup_target failed — see logs for details."

  echo "==> Bootstrap complete. ArgoCD will reconcile remaining stack via gitops/."
}
