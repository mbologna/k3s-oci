#!/usr/bin/env bash
# lib/k3s-argocd.sh -- ArgoCD install, optional app wrappers, hostname ingress.
# Installs ArgoCD via Helm, bootstraps the App of Apps, creates optional ArgoCD
# Application wrappers for feature-gated components, and wires up hostname-specific
# Ingresses + Certificates (e.g. ArgoCD, Longhorn — kept outside gitops/).
# Pure bash -- no Terraform interpolation.
#
# shellcheck disable=SC2154

install_argocd() {
  install_helm

  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

  # Pre-create the ArgoCD repo secret so ArgoCD can clone the gitops repo
  # immediately after install. Must exist before the App of Apps is applied.
  #
  # HTTPS token auth takes precedence when configured. Some git hosts (Codeberg,
  # for one) throttle SSH per source IP, and ArgoCD is a heavy SSH client: every
  # Application opens its own `git ls-remote`, so connection bursts can trip the
  # throttle and stall GitOps entirely. HTTPS is not subject to that there.
  if [[ -n "${VAULT_SECRET_ID_GITOPS_HTTPS_TOKEN}" ]]; then
    echo "Fetching gitops HTTPS token from OCI Vault..."
    local https_token
    if ! https_token=$(fetch_from_vault "${VAULT_SECRET_ID_GITOPS_HTTPS_TOKEN}"); then
      echo "ERROR: Failed to fetch gitops HTTPS token from OCI Vault." >&2
      exit 1
    fi
    [[ -z "${https_token}" ]] && { echo "ERROR: gitops HTTPS token is empty after Vault fetch." >&2; exit 1; }
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
  username: ${GITOPS_HTTPS_USERNAME}
  password: ${https_token}
EOF
    echo "ArgoCD gitops repo HTTPS secret created."
  elif [[ -n "${VAULT_SECRET_ID_GITOPS_SSH_KEY}" ]]; then
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

  # server.insecure=true: Traefik terminates TLS; ArgoCD backend serves plain HTTP.
  # kustomize.buildOptions matches gitops/apps/argocd.yaml: a kustomization with
  # helmCharts fails to render without it, and Argo CD keeps the cached error
  # until a hard refresh even after the self-managed values add it.
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --version "${ARGOCD_CHART_VERSION}" \
    --set "configs.params.server\.insecure=true" \
    --set "configs.cm.kustomize\.buildOptions=--enable-helm" \
    --atomic --wait --timeout 5m

  # Add gitops repo host keys to ArgoCD known hosts so ArgoCD can clone
  # immediately. The Helm chart only includes GitHub/GitLab/Bitbucket by default.
  # Once ArgoCD self-manages via the app-of-apps, configs.ssh.extraHosts in the
  # ArgoCD Application takes over (but we need this to reach that point).
  # SSH-only: an https:// URL has no host key to scan, and the sed below (which
  # keys off the "user@" in an SSH URL) would not match one anyway.
  local repo_host=""
  if [[ "${GITOPS_REPO_URL}" != https://* ]]; then
    repo_host=$(printf '%s' "${GITOPS_REPO_URL}" | sed -n 's|.*@\([^:/]*\).*|\1|p')
  fi
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
# Argo CD repository credentials for OCI Helm charts on registry-1.docker.io
# (none in the default stack since v2.0.0, which dropped Envoy Gateway; useful
# for your own apps). Anonymous Docker Hub pulls are rate-limited; authenticated
# pulls avoid 401/429 errors. Only created when DOCKERHUB_USERNAME is non-empty.

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
    path: ${GITOPS_OPTIONAL_PATH}
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

# if, not `[[ ]] && ...`: a false test as the function's last command makes it
# return 1, and set -e then aborts run_bootstrap before the Ingresses and the
# Longhorn backup target.
create_optional_apps() {
  if [[ "${ENABLE_EXTERNAL_DNS}" == "true" ]]; then
    create_external_dns_app
  fi

  # An empty GITOPS_OPTIONAL_PATH means the gitops repo manages these components
  # itself: cloud-init still installs ESO, but creates no wrapper Application.
  if [[ "${ENABLE_EXTERNAL_SECRETS}" == "true" && -n "${GITOPS_OPTIONAL_PATH}" ]]; then
    create_optional_app "external-secrets" "external-secrets.yaml" "ServerSideApply=true"
  fi
}

# -- External DNS ArgoCD Application -------------------------------------------
# Creates the external-dns Application inline with runtime values (domainFilters,
# zoneIdFilters, txtOwnerId). These cannot be embedded in the static gitops YAML
# because they depend on Terraform variables resolved at plan time.
# The gitops/optional/external-dns.yaml file is a reference template only.
create_external_dns_app() {
  # renovate: datasource=helm depName=external-dns registryUrl=https://kubernetes-sigs.github.io/external-dns
  local chart_version="1.23.0"

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


# -- App ingress (Traefik) ------------------------------------------------------
# One HTTPS host for a Service: a cert-manager Certificate and an Ingress of
# class traefik in the Service's namespace (an Ingress can only use a TLS Secret
# of its own namespace). Traefik's default entrypoint is websecure (TLS), and
# :80 redirects there (gitops/apps/traefik.yaml). Optional Traefik Middlewares
# as a comma-separated list of <namespace>-<name>@kubernetescrd references.
# With a public NLB IP, the Ingress gets an external-dns target annotation:
# Traefik publishes no Ingress status (NodePort Service, IP-free gitops/).

configure_app_ingress() {
  local hostname="$1"
  local namespace="$2"
  local service="$3"
  local port="$4"
  local name="$5"
  local middlewares="${6:-}"

  [[ -z "${hostname}" ]] && return 0

  echo "Configuring ${service} ingress for ${hostname} (${namespace}/${name})..."

  # ArgoCD syncs waves -1 and 0, then the traefik app (wave 1) creates the
  # IngressClass. Allow up to 30 minutes on a fresh deploy.
  local attempts=0
  until kubectl get ingressclass traefik &>/dev/null; do
    attempts=$((attempts + 1))
    [[ ${attempts} -ge 180 ]] && echo "Timeout waiting for IngressClass traefik" && return 1
    echo "  waiting for IngressClass traefik... (${attempts}/180)"
    sleep 10
  done

  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${name}-tls
  namespace: ${namespace}
spec:
  secretName: ${name}-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - "${hostname}"
EOF

  local annotations=""
  [[ -n "${middlewares}" ]] && annotations+="
    traefik.ingress.kubernetes.io/router.middlewares: \"${middlewares}\""
  [[ -n "${PUBLIC_NLB_IP:-}" ]] && annotations+="
    external-dns.alpha.kubernetes.io/target: \"${PUBLIC_NLB_IP}\""

  kubectl apply --server-side --field-manager=cloud-init-bootstrap --force-conflicts -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name}
  namespace: ${namespace}
  annotations:
    traefik.ingress.kubernetes.io/router.tls: "true"${annotations}
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - "${hostname}"
      secretName: ${name}-tls
  rules:
    - host: "${hostname}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${service}
                port:
                  number: ${port}
EOF

  echo "${service} ingress configured: https://${hostname}"
}

# -- ArgoCD ingress -------------------------------------------------------------
# The rate-limit Middleware comes from gitops/argocd/rate-limit.yaml.
configure_argocd_ingress() {
  configure_app_ingress \
    "${ARGOCD_HOSTNAME}" \
    "argocd" \
    "argocd-server" \
    "80" \
    "argocd-server" \
    "argocd-argocd-rate-limit@kubernetescrd"
}

# -- Longhorn ingress -----------------------------------------------------------
configure_longhorn_ingress() {
  [[ -z "${LONGHORN_HOSTNAME}" ]] && return 0

  # BasicAuth for the Longhorn UI: the Secret (key `users`) comes from
  # pre_create_secrets (files/lib/k3s-secrets.sh); the Middleware CRD arrives
  # with the traefik app (wave 1).
  local attempts=0
  until kubectl get crd middlewares.traefik.io &>/dev/null; do
    attempts=$((attempts + 1))
    [[ ${attempts} -ge 180 ]] && echo "Timeout waiting for the Traefik Middleware CRD" && return 1
    echo "  waiting for the Traefik Middleware CRD... (${attempts}/180)"
    sleep 10
  done
  kubectl apply -f - <<EOF
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: longhorn-basic-auth
  namespace: longhorn-system
spec:
  basicAuth:
    secret: longhorn-basic-auth-secret
EOF

  configure_app_ingress \
    "${LONGHORN_HOSTNAME}" \
    "longhorn-system" \
    "longhorn-frontend" \
    "80" \
    "longhorn-frontend" \
    "longhorn-system-longhorn-basic-auth@kubernetescrd"
}
