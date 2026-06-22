#!/usr/bin/env bash
# lib/k3s-argocd.sh -- ArgoCD install, optional app wrappers, Grafana ingress.
# Installs ArgoCD via Helm, bootstraps the App of Apps, creates optional ArgoCD
# Application wrappers for feature-gated components, and wires up the Grafana
# Gateway listener + HTTPRoute (hostname-specific, kept outside gitops/).
# Pure bash -- no Terraform interpolation.
#
# shellcheck disable=SC2154

install_argocd() {
  install_helm

  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

  # Pre-create the ArgoCD SSH repo secret so ArgoCD can clone the gitops repo
  # immediately after install. Must exist before the App of Apps is applied.
  if [[ -n "${VAULT_SECRET_ID_GITOPS_SSH_KEY}" ]]; then
    echo "Fetching gitops SSH deploy key from OCI Vault..."
    local ssh_key
    if ! ssh_key=$(fetch_from_vault "${VAULT_SECRET_ID_GITOPS_SSH_KEY}"); then
      echo "ERROR: Failed to fetch gitops SSH deploy key from OCI Vault." >&2
      exit 1
    fi
    [[ -z "${ssh_key}" ]] && { echo "ERROR: gitops SSH deploy key is empty after Vault fetch." >&2; exit 1; }
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

  # Add gitops repo host keys to ArgoCD known hosts so ArgoCD can clone
  # immediately. The Helm chart only includes GitHub/GitLab/Bitbucket by default.
  # Once ArgoCD self-manages via the app-of-apps, configs.ssh.extraHosts in the
  # ArgoCD Application takes over (but we need this to reach that point).
  local repo_host
  repo_host=$(printf '%s' "${GITOPS_REPO_URL}" | sed -n 's|.*@\([^:/]*\).*|\1|p')
  if [[ -n "${repo_host}" ]]; then
    local known_hosts
    known_hosts=$(ssh-keyscan -T 10 "${repo_host}" 2>/dev/null | grep -v '^#')
    if [[ -n "${known_hosts}" ]]; then
      local existing
      existing=$(kubectl get configmap argocd-ssh-known-hosts-cm -n argocd \
        -o jsonpath='{.data.ssh_known_hosts}' 2>/dev/null || true)
      if ! printf '%s' "${existing}" | grep -q "${repo_host}"; then
        printf '%s\n%s\n' "${existing}" "${known_hosts}" > /tmp/argocd-known-hosts.txt
        kubectl create configmap argocd-ssh-known-hosts-cm -n argocd \
          --from-file=ssh_known_hosts=/tmp/argocd-known-hosts.txt \
          --dry-run=client -o yaml | kubectl apply -f -
        rm -f /tmp/argocd-known-hosts.txt
        echo "Added ${repo_host} to ArgoCD SSH known hosts."
      fi
    fi
  fi

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
      - ServerSideApply=true
EOF
  echo "ArgoCD ${ARGOCD_CHART_VERSION} installed. App of Apps bootstrapped from ${GITOPS_REPO_URL}."
}

# -- DockerHub OCI Helm registry credentials -----------------------------------
# Envoy Gateway chart is hosted on registry-1.docker.io. Anonymous Docker Hub
# pulls are rate-limited; authenticated pulls avoid 401/429 errors in ArgoCD.
# Only created when DOCKERHUB_USERNAME is non-empty.

create_dockerhub_secret() {
  [[ -z "${DOCKERHUB_USERNAME}" ]] && return 0

  # Resolve DockerHub password from OCI Vault when available (plaintext blanked in user-data).
  local dockerhub_password="${DOCKERHUB_PASSWORD}"
  if [[ -n "${VAULT_SECRET_ID_DOCKERHUB:-}" ]]; then
    echo "Fetching DockerHub password from OCI Vault..."
    if ! dockerhub_password=$(fetch_from_vault "${VAULT_SECRET_ID_DOCKERHUB}"); then
      echo "ERROR: Failed to fetch DockerHub password from OCI Vault." >&2; return 1
    fi
    [[ -z "${dockerhub_password}" ]] && { echo "ERROR: DockerHub password is empty after Vault fetch." >&2; return 1; }
  fi

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
  password: "${dockerhub_password}"
EOF
  echo "DockerHub ArgoCD repo credentials created."
}

# -- Optional ArgoCD Applications ----------------------------------------------
# Optional apps live in gitops/optional/ (outside the main app-of-apps scope).
# Cloud-init creates thin wrapper ArgoCD Applications here so that ArgoCD
# only deploys an optional component when its feature flag is enabled.

# create_optional_app <app-name> <filename> [extra_sync_option...]
# Creates a single ArgoCD Application pointing at gitops/optional/<filename>.
create_optional_app() {
  local app_name="$1"
  local filename="$2"
  shift 2
  local extra_sync_options=("$@")

  local sync_options_yaml="      - CreateNamespace=true"
  for opt in "${extra_sync_options[@]}"; do
    sync_options_yaml="${sync_options_yaml}
      - ${opt}"
  done

  kubectl apply -n argocd -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: optional-${app_name}
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
      include: "${filename}"
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
${sync_options_yaml}
EOF
  echo "optional-${app_name} ArgoCD Application created."
}

create_optional_apps() {
  [[ "${ENABLE_EXTERNAL_DNS}" == "true" ]] && create_external_dns_app

  [[ "${ENABLE_EXTERNAL_SECRETS}" == "true" ]] && \
    create_optional_app "external-secrets" "external-secrets.yaml" "ServerSideApply=true"
}

# -- External DNS ArgoCD Application -------------------------------------------
# Creates the external-dns Application inline with runtime values (domainFilters,
# zoneIdFilters, txtOwnerId). These cannot be embedded in the static gitops YAML
# because they depend on Terraform variables resolved at plan time.
# The gitops/optional/external-dns.yaml file is a reference template only.
create_external_dns_app() {
  # renovate: datasource=helm depName=external-dns registryUrl=https://kubernetes-sigs.github.io/external-dns
  local chart_version="1.21.1"

  kubectl apply -n argocd -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: external-dns
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://kubernetes-sigs.github.io/external-dns
    chart: external-dns
    targetRevision: "${chart_version}"
    helm:
      valuesObject:
        provider:
          name: cloudflare
        env:
          - name: CF_API_TOKEN
            valueFrom:
              secretKeyRef:
                name: cloudflare-credentials
                key: apiToken
        # policy=sync: external-dns will also delete DNS records for removed resources.
        # Use policy=upsert-only to prevent deletions if you manage DNS elsewhere.
        policy: sync
        # Restrict external-dns to manage only records within this domain.
        domainFilters:
          - "${EXTERNAL_DNS_DOMAIN_FILTER}"
        # Scope the Cloudflare zone to avoid touching unrelated zones in the account.
        zoneIdFilters:
          - "${CLOUDFLARE_ZONE_ID}"
        # txtOwnerId scopes TXT ownership records so multiple clusters can share a
        # Cloudflare zone without conflicting with each other.
        txtOwnerId: "${CLUSTER_NAME}"
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            memory: 64Mi
  destination:
    server: https://kubernetes.default.svc
    namespace: external-dns
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
  echo "external-dns ArgoCD Application created (domain=${EXTERNAL_DNS_DOMAIN_FILTER}, zone=${CLOUDFLARE_ZONE_ID}, owner=${CLUSTER_NAME})."
}

# -- Generic app ingress helper ------------------------------------------------
# configure_app_ingress <hostname> <namespace> <service> <port> <listener_name> [route_name]
#
# Creates (or updates) three resources for an HTTPS-terminated app:
#   1. A Gateway listener named <listener_name> (SSA, field-manager=cloud-init-bootstrap)
#   2. A cert-manager Certificate in envoy-gateway-system
#   3. An HTTPRoute named <route_name> (defaults to <service>) in <namespace>
#      with <hostname> (SSA, field-manager=cloud-init-bootstrap)
#
# <route_name> is optional and defaults to <service>. Set it explicitly when the
# gitops HTTPRoute file uses a different name from the backend service (e.g. grafana
# HTTPRoute is named "grafana" while the service is "kube-prometheus-stack-grafana").
#
# All resources survive ArgoCD reconciliation because cloud-init-bootstrap owns
# the specific fields; ArgoCD never claims them.
configure_app_ingress() {
  local hostname="$1"
  local namespace="$2"
  local service="$3"
  local port="$4"
  local listener_name="$5"
  local route_name="${6:-${service}}"

  [[ -z "${hostname}" ]] && return 0

  echo "Configuring ${service} ingress for ${hostname} (listener=${listener_name}, route=${route_name})..."

  # ArgoCD must complete wave-0 apps, then envoy-gateway (wave 1), then
  # gateway-config (wave 2) before Gateway eg exists. Allow up to 30 minutes.
  local attempts=0
  until kubectl get gateway eg -n envoy-gateway-system &>/dev/null; do
    attempts=$((attempts + 1))
    [[ ${attempts} -ge 180 ]] && echo "Timeout waiting for Gateway eg" && return 1
    echo "  waiting for Gateway eg... (${attempts}/180)"
    sleep 10
  done

  kubectl apply --server-side --field-manager=cloud-init-bootstrap --force-conflicts -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: envoy-gateway-system
spec:
  gatewayClassName: eg
  listeners:
    - name: ${listener_name}
      port: 443
      protocol: HTTPS
      hostname: "${hostname}"
      tls:
        mode: Terminate
        certificateRefs:
          - name: ${listener_name}-tls
      allowedRoutes:
        namespaces:
          from: All
EOF

  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${listener_name}-tls
  namespace: envoy-gateway-system
spec:
  secretName: ${listener_name}-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - "${hostname}"
EOF

  kubectl apply --server-side --field-manager=cloud-init-bootstrap --force-conflicts -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${route_name}
  namespace: ${namespace}
spec:
  parentRefs:
    - name: eg
      namespace: envoy-gateway-system
      sectionName: ${listener_name}
  hostnames:
    - "${hostname}"
  rules:
    - backendRefs:
        - name: ${service}
          port: ${port}
EOF

  echo "${service} ingress configured: https://${hostname}"
}

# -- Grafana ingress (hostname-specific, created outside gitops/) ---------------
# The Gateway listener, TLS Certificate, and Grafana HTTPRoute are IP-specific
# (hostname includes the NLB IP). They are created here so that gitops/ files
# remain IP-independent across redeployments. ArgoCD gateway-config is configured
# to ignore differences in Gateway spec.listeners so these survive reconciliation.
#
# The HTTPRoute is named "grafana" (matching gitops/monitoring/grafana-ingress.yaml)
# so that cloud-init-bootstrap owns spec.hostnames via SSA while ArgoCD owns the
# rest of the manifest. monitoring-extras app ignoreDifferences covers /spec/hostnames.

configure_grafana_ingress() {
  configure_app_ingress \
    "${GRAFANA_HOSTNAME}" \
    "monitoring" \
    "kube-prometheus-stack-grafana" \
    "80" \
    "https-grafana" \
    "grafana"

  # The HTTP->HTTPS redirect HTTPRoute (gitops/gateway/redirect.yaml) intentionally
  # has no hostnames and matches ALL HTTP traffic. The ACME challenge HTTPRoute
  # (created by cert-manager) has a more specific hostname+path match and takes
  # precedence. No patching of the redirect route is needed.
}

# -- ArgoCD ingress -------------------------------------------------------------
configure_argocd_ingress() {
  configure_app_ingress \
    "${ARGOCD_HOSTNAME}" \
    "argocd" \
    "argocd-server" \
    "80" \
    "https-argocd"
}

# -- Longhorn ingress -----------------------------------------------------------
configure_longhorn_ingress() {
  [[ -z "${LONGHORN_HOSTNAME}" ]] && return 0

  configure_app_ingress \
    "${LONGHORN_HOSTNAME}" \
    "longhorn-system" \
    "longhorn-frontend" \
    "80" \
    "https-longhorn"

  # Apply BasicAuth SecurityPolicy so the Longhorn UI requires credentials.
  kubectl apply -f - <<EOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: longhorn-basic-auth
  namespace: longhorn-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: longhorn-frontend
  basicAuth:
    users:
      name: longhorn-basic-auth-secret
EOF
}
