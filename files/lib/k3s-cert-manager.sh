#!/usr/bin/env bash
# lib/k3s-cert-manager.sh -- cert-manager Helm install + ClusterIssuers bootstrap.
# Installed before ArgoCD so ClusterIssuers with the real Let's Encrypt email address
# exist when ArgoCD first syncs. ArgoCD adopts the Helm release via gitops/apps/cert-manager.yaml.
# Pure bash -- no Terraform interpolation.
#
# shellcheck disable=SC2154

# apply_cluster_issuer <name> <acme_server_url> <solver_yaml>
# Creates a cert-manager ClusterIssuer with the given name, ACME server URL,
# and solver block (indented YAML string). Reusable for staging/prod x http01/dns01.
apply_cluster_issuer() {
  local name="$1"
  local server="$2"
  local solver_yaml="$3"

  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${name}
spec:
  acme:
    server: ${server}
    email: ${CERTMANAGER_EMAIL}
    privateKeySecretRef:
      name: ${name}
    solvers:
${solver_yaml}
EOF
}

install_certmanager() {
  install_helm

  helm repo add jetstack https://charts.jetstack.io || { echo "ERROR: helm repo add jetstack failed."; exit 1; }
  helm repo update

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version "${CERTMANAGER_CHART_VERSION}" \
    --set crds.enabled=true \
    --set "extraArgs[0]=--feature-gates=ExperimentalGatewayAPISupport=true" \
    --set prometheus.servicemonitor.enabled=true \
    --set prometheus.servicemonitor.labels.release=kube-prometheus-stack \
    --atomic --wait --timeout 5m

  if [[ "${ENABLE_DNS01_CHALLENGE}" == "true" ]]; then
    # DNS-01 challenge via Cloudflare -- supports wildcard certs, no inbound port 80 required.
    kubectl apply -n cert-manager -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
type: Opaque
stringData:
  api-token: "${CLOUDFLARE_API_TOKEN}"
EOF

    local dns01_solver
    dns01_solver="      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token"

    apply_cluster_issuer "letsencrypt-staging" \
      "https://acme-staging-v02.api.letsencrypt.org/directory" \
      "${dns01_solver}"

    apply_cluster_issuer "letsencrypt-prod" \
      "https://acme-v02.api.letsencrypt.org/directory" \
      "${dns01_solver}"
  else
    # HTTP-01 solver uses Gateway API (gatewayHTTPRoute) -- no Ingress controller needed.
    # Bootstrap ClusterIssuers with the correct email address.
    # Adoptable by ArgoCD via gitops/cert-manager/ (update email in cluster-issuers.yaml first).
    local http01_solver
    http01_solver="      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: eg
                namespace: envoy-gateway-system
                kind: Gateway"

    apply_cluster_issuer "letsencrypt-staging" \
      "https://acme-staging-v02.api.letsencrypt.org/directory" \
      "${http01_solver}"

    apply_cluster_issuer "letsencrypt-prod" \
      "https://acme-v02.api.letsencrypt.org/directory" \
      "${http01_solver}"
  fi

  echo "cert-manager ${CERTMANAGER_CHART_VERSION} installed with ClusterIssuers (email: ${CERTMANAGER_EMAIL})."
  echo "See gitops/cert-manager/ to adopt ClusterIssuers into ArgoCD."
}
