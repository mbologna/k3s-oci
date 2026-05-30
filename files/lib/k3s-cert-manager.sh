#!/usr/bin/env bash
# lib/k3s-cert-manager.sh -- cert-manager Helm install + ClusterIssuers bootstrap.
# Installed before ArgoCD so ClusterIssuers with the real Let's Encrypt email address
# exist when ArgoCD first syncs. ArgoCD adopts the Helm release via gitops/apps/cert-manager.yaml.
# Pure bash -- no Terraform interpolation.
#
# shellcheck disable=SC2154

install_certmanager() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  install_helm

  helm repo add jetstack https://charts.jetstack.io
  helm repo update

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version "${CERTMANAGER_CHART_VERSION}" \
    --set crds.enabled=true \
    --set "extraArgs[0]=--feature-gates=ExperimentalGatewayAPISupport=true" \
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

    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${CERTMANAGER_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
EOF

    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${CERTMANAGER_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
EOF
  else
    # HTTP-01 solver uses Gateway API (gatewayHTTPRoute) -- no Ingress controller needed.
    # Bootstrap ClusterIssuers with the correct email address.
    # Adoptable by ArgoCD via gitops/cert-manager/ (update email in cluster-issuers.yaml first).
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${CERTMANAGER_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: eg
                namespace: envoy-gateway-system
                kind: Gateway
EOF

    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${CERTMANAGER_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: eg
                namespace: envoy-gateway-system
                kind: Gateway
EOF
  fi

  echo "cert-manager ${CERTMANAGER_CHART_VERSION} installed with ClusterIssuers (email: ${CERTMANAGER_EMAIL})."
  echo "See gitops/cert-manager/ to adopt ClusterIssuers into ArgoCD."
}
