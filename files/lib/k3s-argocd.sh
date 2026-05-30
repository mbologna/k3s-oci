#!/usr/bin/env bash
# lib/k3s-argocd.sh -- ArgoCD install, optional app wrappers, Grafana ingress.
# Installs ArgoCD via Helm, bootstraps the App of Apps, creates optional ArgoCD
# Application wrappers for feature-gated components, and wires up the Grafana
# Gateway listener + HTTPRoute (hostname-specific, kept outside gitops/).
# Pure bash -- no Terraform interpolation.
#
# shellcheck disable=SC2154

install_argocd() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  install_helm

  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

  # Pre-create the ArgoCD SSH repo secret so ArgoCD can clone the gitops repo
  # immediately after install. Must exist before the App of Apps is applied.
  if [[ -n "${VAULT_SECRET_ID_GITOPS_SSH_KEY}" ]]; then
    echo "Fetching gitops SSH deploy key from OCI Vault..."
    local ssh_key
    ssh_key=$(oci secrets secret-bundle get \
      --secret-id "${VAULT_SECRET_ID_GITOPS_SSH_KEY}" \
      --query 'data."secret-bundle-content".content' --raw-output | base64 -d)
    kubectl apply -n argocd -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-repo-gitops
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${GITOPS_REPO_URL}
  sshPrivateKey: |
$(printf '%s\n' "${ssh_key}" | awk '{print "    " $0}')
EOF
    echo "ArgoCD gitops repo SSH secret created."
  fi

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
    path: ${GITOPS_PATH}
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

  # Patch Gateway: add the https-grafana listener using Server-Side Apply with a
  # custom field manager. Gateway API defines spec.listeners as a list-map keyed
  # on `name`, so SSA merges by key — the existing `http` listener (owned by
  # argocd-controller from gateway.yaml) is preserved. cloud-init-bootstrap owns
  # the `https-grafana` entry; ArgoCD (applying gateway.yaml without this listener)
  # does not own it and will not remove it.
  # ignoreDifferences: /spec/listeners in gateway-config prevents OutOfSync alerts.
  kubectl apply --server-side --field-manager=cloud-init-bootstrap --force-conflicts -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: envoy-gateway-system
spec:
  gatewayClassName: eg
  listeners:
    - name: https-grafana
      port: 443
      protocol: HTTPS
      hostname: "${GRAFANA_HOSTNAME}"
      tls:
        mode: Terminate
        certificateRefs:
          - name: grafana-tls
      allowedRoutes:
        namespaces:
          from: All
EOF

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
  # Use Server-Side Apply with a custom field manager so cloud-init "owns" the
  # hostnames field. ArgoCD's SSA (field-manager=argocd-controller) applies
  # grafana-ingress.yaml without spec.hostnames → it won't own or clear this field.
  kubectl apply --server-side --field-manager=cloud-init-bootstrap --force-conflicts -f - <<EOF
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

  # The HTTP->HTTPS redirect HTTPRoute (gitops/gateway/redirect.yaml) intentionally
  # has no hostnames and matches ALL HTTP traffic. The ACME challenge HTTPRoute
  # (created by cert-manager) has a more specific hostname+path match and takes
  # precedence. No patching of the redirect route is needed.

  echo "Grafana ingress configured: https://${GRAFANA_HOSTNAME}"
}
