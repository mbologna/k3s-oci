#!/usr/bin/env bash
# lib/k3s-external-secrets.sh -- External Secrets Operator install + ClusterSecretStore.
# Installed at bootstrap so the CRD exists before ArgoCD creates ExternalSecret resources.
# Bootstrap also creates the ClusterSecretStore pointing to OCI Vault via instance_principal.
# ArgoCD adopts the Helm release via gitops/apps/external-secrets.yaml.
# Pure bash -- no Terraform interpolation.
#
# shellcheck disable=SC2154

install_external_secrets() {
  install_helm

  if [[ -z "${VAULT_OCID:-}" || -z "${OCI_REGION:-}" ]]; then
    echo "ERROR: install_external_secrets requires VAULT_OCID and OCI_REGION to be set."
    echo "  Ensure enable_vault=true and region is configured in your Terraform variables."
    exit 1
  fi

  helm repo add external-secrets https://charts.external-secrets.io || { echo "ERROR: helm repo add external-secrets failed."; exit 1; }
  helm repo update

  helm upgrade --install external-secrets external-secrets/external-secrets \
    --namespace external-secrets --create-namespace \
    --version "${EXTERNAL_SECRETS_CHART_VERSION}" \
    --atomic --wait --timeout 5m

  # Wait for the ClusterSecretStore CRD to be established before applying.
  # The CRD is created by the Helm chart but may not be registered in the API
  # server immediately after helm reports success.
  kubectl wait --for condition=established \
    --timeout=120s crd/clustersecretstores.external-secrets.io

  # ClusterSecretStore pointing to OCI Vault via instance_principal.
  # Adoptable into ArgoCD via gitops/external-secrets/.
  # ESO v2+ uses external-secrets.io/v1; omitting auth = instance principal.
  kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: oci-vault
spec:
  provider:
    oracle:
      vault: "${VAULT_OCID}"
      region: "${OCI_REGION}"
EOF

  echo "External Secrets Operator ${EXTERNAL_SECRETS_CHART_VERSION} installed. ClusterSecretStore 'oci-vault' ready."
  echo "See gitops/external-secrets/ for ExternalSecret examples."
}
