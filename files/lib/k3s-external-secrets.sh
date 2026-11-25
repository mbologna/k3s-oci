#!/usr/bin/env bash
# lib/k3s-external-secrets.sh -- External Secrets Operator install + ClusterSecretStore.
# Installed at bootstrap so the CRD exists before ArgoCD creates ExternalSecret resources.
# Bootstrap also creates the ClusterSecretStore pointing to OCI Vault: via instance_principal,
# or via the module's service user when create_external_secrets_user = true.
# ArgoCD adopts the Helm release via gitops/optional/external-secrets.yaml (only when
# enable_external_secrets = true -- see create_optional_apps() in k3s-argocd.sh).
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
    --set webhook.create=false --set certController.create=false \
    --atomic --wait --timeout 5m

  # Wait for the ClusterSecretStore CRD to be established before applying.
  # The CRD is created by the Helm chart but may not be registered in the API
  # server immediately after helm reports success.
  kubectl wait --for condition=established \
    --timeout=120s crd/clustersecretstores.external-secrets.io

  if [[ -n "${ESO_USER_OCID:-}" ]]; then
    create_eso_user_store
  else
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
  fi

  echo "External Secrets Operator ${EXTERNAL_SECRETS_CHART_VERSION} installed. ClusterSecretStore 'oci-vault' ready."
  echo "See gitops/external-secrets/ for ExternalSecret examples."
}

# create_eso_user_store (create_external_secrets_user)
# The store authenticates as the module's vault-scoped service user: its API
# private key comes from Vault (never user-data) into the oci-api-key Secret.
create_eso_user_store() {
  local key_file
  key_file=$(mktemp)
  chmod 600 "${key_file}"
  if ! fetch_from_vault "${VAULT_SECRET_ID_ESO_API_KEY}" > "${key_file}"; then
    rm -f "${key_file}"
    echo "ERROR: could not fetch the External Secrets API key from Vault."
    exit 1
  fi
  kubectl -n external-secrets create secret generic oci-api-key \
    --from-file=privateKey="${key_file}" \
    --from-literal=fingerprint="${ESO_API_KEY_FINGERPRINT}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -f "${key_file}"

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
      auth:
        tenancy: "${ESO_TENANCY_OCID}"
        user: "${ESO_USER_OCID}"
        secretRef:
          privatekey:
            name: oci-api-key
            key: privateKey
            namespace: external-secrets
          fingerprint:
            name: oci-api-key
            key: fingerprint
            namespace: external-secrets
EOF
  echo "ClusterSecretStore 'oci-vault' uses service user ${ESO_USER_OCID} (create_external_secrets_user)."
}
