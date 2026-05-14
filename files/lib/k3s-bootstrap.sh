#!/usr/bin/env bash
# lib/k3s-bootstrap.sh -- first-server stack bootstrap: secrets pre-creation,
# Gateway API CRDs, cert-manager + ClusterIssuers, External Secrets, ArgoCD.
# Called by k3s-server.sh via run_bootstrap() after the cluster is Ready.
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

# -- Pre-create runtime Kubernetes Secrets -------------------------------------
# These secrets contain values generated or resolved at Terraform apply time
# (random passwords, Vault-fetched secrets, runtime endpoints). They must exist
# before the ArgoCD apps that reference them sync.

pre_create_secrets() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  # Resolve passwords from OCI Vault or from plain-text user-data header
  if [[ -n "${VAULT_SECRET_ID_LONGHORN_PASSWORD}" ]]; then
    echo "Fetching Longhorn UI password from OCI Vault..."
    LONGHORN_UI_PASSWORD=$(oci secrets secret-bundle get \
      --secret-id "${VAULT_SECRET_ID_LONGHORN_PASSWORD}" \
      --query 'data."secret-bundle-content".content' --raw-output | base64 -d)
  else
    LONGHORN_UI_PASSWORD="${LONGHORN_UI_PASSWORD_PLAIN}"
  fi

  if [[ -n "${VAULT_SECRET_ID_GRAFANA_PASSWORD}" ]]; then
    echo "Fetching Grafana admin password from OCI Vault..."
    GRAFANA_ADMIN_PASSWORD=$(oci secrets secret-bundle get \
      --secret-id "${VAULT_SECRET_ID_GRAFANA_PASSWORD}" \
      --query 'data."secret-bundle-content".content' --raw-output | base64 -d)
  else
    GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD_PLAIN}"
  fi

  # Longhorn BasicAuth -- htpasswd hash generated here because openssl apr1 hashing
  # is not possible inside static gitops YAML. Secret is referenced by
  # gitops/longhorn/ingress.yaml (user-configured HTTPRoute + SecurityPolicy).
  local longhorn_hash
  longhorn_hash=$(openssl passwd -apr1 "${LONGHORN_UI_PASSWORD}")
  kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n longhorn-system -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: longhorn-basic-auth-secret
  namespace: longhorn-system
type: Opaque
stringData:
  .htpasswd: "${LONGHORN_UI_USERNAME}:${longhorn_hash}"
EOF
  echo "Longhorn BasicAuth secret created."

  # Grafana admin secret -- referenced by kube-prometheus-stack ArgoCD app
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n monitoring -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin-secret
  namespace: monitoring
type: Opaque
stringData:
  admin-user: admin
  admin-password: "${GRAFANA_ADMIN_PASSWORD}"
EOF
  echo "Grafana admin secret pre-created in monitoring namespace."

  # Alertmanager config -- always created so kube-prometheus-stack can reference
  # it via alertmanagerSpec.configSecret. Null receiver when OCI Notifications is
  # disabled; OCI webhook receiver when enabled.
  if [[ -n "${NOTIFICATION_TOPIC_ENDPOINT}" ]]; then
    kubectl apply -n monitoring -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-oci-config
  namespace: monitoring
type: Opaque
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: 'oci-notifications'
    receivers:
    - name: 'oci-notifications'
      webhook_configs:
      - url: '${NOTIFICATION_TOPIC_ENDPOINT}'
        send_resolved: true
EOF
  else
    kubectl apply -n monitoring -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-oci-config
  namespace: monitoring
type: Opaque
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: 'null'
    receivers:
    - name: 'null'
EOF
  fi
  echo "Alertmanager config secret created."

  # MySQL credentials -- pre-created so apps can mount this secret on first deploy
  if [[ -n "${MYSQL_ENDPOINT}" ]]; then
    kubectl apply -n default -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mysql-credentials
  namespace: default
type: Opaque
stringData:
  host: "${MYSQL_ENDPOINT}"
  username: "${MYSQL_ADMIN_USERNAME}"
  password: "${MYSQL_ADMIN_PASSWORD}"
  jdbc-url: "jdbc:mysql://${MYSQL_ENDPOINT}/${CLUSTER_NAME}?useSSL=true&requireSSL=true"
EOF
    echo "MySQL credentials secret created (host: ${MYSQL_ENDPOINT})."
  fi

  # Cloudflare credentials for external-dns -- pre-created so the ArgoCD
  # external-dns app (gitops/apps/external-dns.yaml) starts reconciling immediately.
  if [[ "${ENABLE_EXTERNAL_DNS}" == "true" ]]; then
    kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n external-dns -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-credentials
  namespace: external-dns
type: Opaque
stringData:
  apiToken: "${CLOUDFLARE_API_TOKEN}"
EOF
    echo "Cloudflare credentials secret created for external-dns."
  fi
}

# -- cert-manager --------------------------------------------------------------
# Installed at bootstrap (not via ArgoCD) so ClusterIssuers with the real
# Let's Encrypt email address exist before ArgoCD syncs cert-manager.
# ArgoCD adopts the Helm release once the cert-manager app syncs.

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

# -- External Secrets Operator -------------------------------------------------
# Installed at bootstrap so the CRD exists before ArgoCD creates ExternalSecret
# resources. Bootstrap also creates the ClusterSecretStore pointing to OCI Vault.
# ArgoCD adopts the Helm release once the external-secrets app syncs.

install_external_secrets() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  install_helm

  helm repo add external-secrets https://charts.external-secrets.io
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

# -- ArgoCD + App of Apps ------------------------------------------------------
# Installs ArgoCD via Helm then bootstraps the App of Apps so ArgoCD
# self-manages all of gitops/ going forward.

install_argocd() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  install_helm

  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update

  # server.insecure=true: Envoy Gateway terminates TLS; ArgoCD backend serves plain HTTP.
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --version "${ARGOCD_CHART_VERSION}" \
    --set "configs.params.server\.insecure=true" \
    --atomic --wait --timeout 5m

  # Bootstrap the App of Apps so ArgoCD self-manages gitops/
  kubectl apply -n argocd -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${GITOPS_REPO_URL}
    targetRevision: HEAD
    path: gitops/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
  echo "ArgoCD ${ARGOCD_CHART_VERSION} installed. App of Apps bootstrapped from ${GITOPS_REPO_URL}."
}

# -- DockerHub OCI Helm registry credentials -----------------------------------
# Envoy Gateway chart is hosted on registry-1.docker.io. Anonymous Docker Hub
# pulls are rate-limited; authenticated pulls avoid 401/429 errors in ArgoCD.
# Only created when DOCKERHUB_USERNAME is non-empty.

create_dockerhub_secret() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  [[ -z "${DOCKERHUB_USERNAME}" ]] && return 0

  kubectl apply -n argocd -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: dockerhub-registry
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  url: registry-1.docker.io
  type: helm
  enableOCI: "true"
  username: "${DOCKERHUB_USERNAME}"
  password: "${DOCKERHUB_PASSWORD}"
EOF
  echo "DockerHub ArgoCD repo credentials created."
}

# -- Optional ArgoCD Applications ----------------------------------------------
# Optional apps live in gitops/optional/ (outside the main app-of-apps scope).
# Cloud-init creates thin wrapper ArgoCD Applications here so that ArgoCD
# only deploys an optional component when its feature flag is enabled.
# Each wrapper points to a single file in gitops/optional/ via directory.include,
# which ArgoCD then applies -- creating the actual ArgoCD Application for the
# Helm chart. This is the standard app-of-apps pattern, kept conditional.

create_optional_apps() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  if [[ "${ENABLE_EXTERNAL_DNS}" == "true" ]]; then
    kubectl apply -n argocd -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: optional-external-dns
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${GITOPS_REPO_URL}
    targetRevision: HEAD
    path: gitops/optional
    directory:
      include: "external-dns.yaml"
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
    echo "optional-external-dns ArgoCD Application created."
  fi

  if [[ "${ENABLE_EXTERNAL_SECRETS}" == "true" ]]; then
    kubectl apply -n argocd -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: optional-external-secrets
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${GITOPS_REPO_URL}
    targetRevision: HEAD
    path: gitops/optional
    directory:
      include: "external-secrets.yaml"
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOF
    echo "optional-external-secrets ArgoCD Application created."
  fi
}
# -- Grafana ingress (hostname-specific, created outside gitops/) ---------------
# The Gateway listener, TLS Certificate, and Grafana HTTPRoute are IP-specific
# (hostname includes the NLB IP). They are created here so that gitops/ files
# remain IP-independent across redeployments. ArgoCD gateway-config is configured
# to ignore differences in Gateway spec.listeners so these survive reconciliation.

configure_grafana_ingress() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  [[ -z "${GRAFANA_HOSTNAME}" ]] && return 0

  echo "Configuring Grafana ingress for ${GRAFANA_HOSTNAME}..."

  # Wait for the Gateway to exist (ArgoCD syncs gateway-config after install_argocd).
  local attempts=0
  until kubectl get gateway eg -n envoy-gateway-system &>/dev/null; do
    attempts=$((attempts + 1))
    [[ ${attempts} -ge 60 ]] && echo "Timeout waiting for Gateway eg" && return 1
    echo "  waiting for Gateway eg... (${attempts}/60)"
    sleep 10
  done

  # Patch Gateway: add the https-grafana listener (idempotent -- remove first if present).
  kubectl get gateway eg -n envoy-gateway-system -o json \
    | python3 -c "
import sys, json
gw = json.load(sys.stdin)
listeners = [l for l in gw['spec'].get('listeners', []) if l.get('name') != 'https-grafana']
listeners.append({
  'name': 'https-grafana',
  'port': 443,
  'protocol': 'HTTPS',
  'hostname': '${GRAFANA_HOSTNAME}',
  'tls': {'mode': 'Terminate', 'certificateRefs': [{'name': 'grafana-tls'}]},
  'allowedRoutes': {'namespaces': {'from': 'All'}}
})
gw['spec']['listeners'] = listeners
print(json.dumps(gw))
" | kubectl apply -f -

  # Create (or update) the TLS Certificate.
  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: grafana-tls
  namespace: envoy-gateway-system
spec:
  secretName: grafana-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - "${GRAFANA_HOSTNAME}"
EOF

  # Create (or update) the Grafana HTTPRoute in the monitoring namespace.
  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
  namespace: monitoring
spec:
  parentRefs:
    - name: eg
      namespace: envoy-gateway-system
      sectionName: https-grafana
  hostnames:
    - "${GRAFANA_HOSTNAME}"
  rules:
    - backendRefs:
        - name: kube-prometheus-stack-grafana
          port: 80
EOF

  # Patch the HTTP->HTTPS redirect HTTPRoute to include this hostname.
  # Wait for the HTTPRoute to exist first.
  local rt_attempts=0
  until kubectl get httproute http-to-https-redirect -n envoy-gateway-system &>/dev/null; do
    rt_attempts=$((rt_attempts + 1))
    [[ ${rt_attempts} -ge 30 ]] && echo "Timeout waiting for http-to-https-redirect HTTPRoute" && return 1
    sleep 10
  done

  # Add hostname to redirect route if not already present (idempotent).
  kubectl get httproute http-to-https-redirect -n envoy-gateway-system -o json \
    | python3 -c "
import sys, json
rt = json.load(sys.stdin)
hostnames = rt['spec'].get('hostnames', [])
if '${GRAFANA_HOSTNAME}' not in hostnames:
    hostnames.append('${GRAFANA_HOSTNAME}')
rt['spec']['hostnames'] = hostnames
print(json.dumps(rt))
" | kubectl apply -f -

  echo "Grafana ingress configured: https://${GRAFANA_HOSTNAME}"
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
  configure_grafana_ingress
  echo "==> Bootstrap complete. ArgoCD will reconcile remaining stack via gitops/."
}
