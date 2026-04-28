#!/bin/bash
# k3s-install-server.sh — cloud-init for k3s control-plane nodes (Ubuntu 24.04+)
# Templated by Terraform. Use $${var} for literal bash; Terraform interpolates before upload.
# shellcheck disable=SC2154,SC1083,SC2288,SC2066,SC2034

set -euo pipefail
exec > >(tee /var/log/k3s-cloud-init.log | logger -t k3s-cloud-init) 2>&1

echo "==> k3s server cloud-init starting at $(date -u)"

# ── Wait for kubeapi ──────────────────────────────────────────────────────────

wait_for_kubeapi() {
  local max_attempts=60 attempt=0
  echo "Waiting for k3s API at ${k3s_url}:6443 ..."
  until curl --output /dev/null --silent --insecure "https://${k3s_url}:6443"; do
    attempt=$(( attempt + 1 ))
    if [[ $attempt -ge $max_attempts ]]; then
      echo "ERROR: kubeapi not reachable after $${max_attempts} attempts."
      exit 1
    fi
    echo "  attempt $${attempt}/$${max_attempts} — sleeping 10s"
    sleep 10
  done
  echo "kubeapi is reachable."
}

# ── OS bootstrap ──────────────────────────────────────────────────────────────

bootstrap() {
  /usr/sbin/netfilter-persistent stop  || true
  /usr/sbin/netfilter-persistent flush || true
  systemctl stop    netfilter-persistent.service || true
  systemctl disable netfilter-persistent.service || true

  # OCI instances only have IPv4 routes; force apt to avoid IPv6 mirror timeouts
  echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

  export DEBIAN_FRONTEND=noninteractive
  # Tolerate partial mirror failures (transient OCI regional mirror issues)
  apt-get update -q || apt-get update -q || true
  apt-get install -y -q --no-install-recommends \
    software-properties-common jq curl python3 python3-pip \
    open-iscsi util-linux
  apt-get upgrade -y -q
  apt-get clean
  rm -rf /var/lib/apt/lists/*

  # Cap journal size to protect the boot volume
  echo "SystemMaxUse=100M"      >> /etc/systemd/journald.conf
  echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf
  systemctl restart systemd-journald
}

# ── Unattended upgrades ───────────────────────────────────────────────────────

configure_unattended_upgrades() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q || apt-get update -q || true
  apt-get install -y -q --no-install-recommends unattended-upgrades apt-listchanges needrestart
  apt-get clean
  rm -rf /var/lib/apt/lists/*

  cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UUEOF'
Unattended-Upgrade::Allowed-Origins {
    "$${distro_id}:$${distro_codename}";
    "$${distro_id}:$${distro_codename}-security";
    "$${distro_id}ESMApps:$${distro_codename}-apps-security";
    "$${distro_id}ESM:$${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
// kured handles reboots — never auto-reboot here
Unattended-Upgrade::Automatic-Reboot "false";
UUEOF

  cat > /etc/apt/apt.conf.d/20auto-upgrades << 'UUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
UUEOF

  # needrestart: automatically restart affected userspace services after package
  # updates (mode 'a' = automatic). This ensures CVE patches for running daemons
  # (nginx, openssl-linked services, etc.) take effect immediately without waiting
  # for the kured reboot window. k3s is excluded — its lifecycle is managed by
  # the cluster upgrade controller, not apt.
  mkdir -p /etc/needrestart/conf.d
  cat > /etc/needrestart/conf.d/99-k3s.conf << 'NREOF'
$nrconf{restart} = 'a';
$nrconf{blacklist_rc} = [qr(^k3s)];
NREOF

  # Do NOT pin apt-daily-upgrade to the kured maintenance window.
  # Patches must install on Ubuntu's default daily schedule so CVE fixes are
  # applied as soon as packages are available. Only the reboot is deferred to
  # the kured window (kured_start_time–kured_end_time on kured_reboot_days).
  # A 60-minute RandomizedDelaySec staggers nodes to avoid simultaneous dpkg locks.
  mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
  cat > /etc/systemd/system/apt-daily-upgrade.timer.d/stagger.conf << 'TIMEREOF'
[Timer]
RandomizedDelaySec=60min
TIMEREOF
  systemctl daemon-reload
  systemctl restart apt-daily-upgrade.timer

  systemctl enable --now unattended-upgrades
}

# ── OCI CLI (pinned; used for first-server detection via instance_principal) ──

install_oci_cli() {
  if /root/bin/oci --version &>/dev/null 2>&1; then
    echo "OCI CLI already installed, skipping."
    return 0
  fi
  bash -c "$(curl -sfL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" \
    -- --accept-all-defaults
  # Suppress OCI CLI announcements so they never pollute stdout of subsequent
  # oci commands (announcements on stdout break pipes to jq / base64).
  # Ensure suppress_feedback is set in [OCI_CLI_SETTINGS], creating or updating
  # the section. The installer may already write [OCI_CLI_SETTINGS], so we use
  # python3 to set the key idempotently rather than blindly appending.
  python3 - <<'RCEOF'
import configparser, os
rc = os.path.expanduser('~/.oci/oci_cli_rc')
os.makedirs(os.path.dirname(rc), exist_ok=True)
cfg = configparser.ConfigParser()
cfg.read(rc)
if not cfg.has_section('OCI_CLI_SETTINGS'):
    cfg.add_section('OCI_CLI_SETTINGS')
cfg.set('OCI_CLI_SETTINGS', 'suppress_feedback', 'True')
with open(rc, 'w') as f:
    cfg.write(f)
RCEOF
}

# ── Helm ──────────────────────────────────────────────────────────────────────

install_helm() {
  command -v helm &>/dev/null && return 0
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

# ── Ingress: Envoy Gateway (Gateway API) ─────────────────────────────────────

install_envoy_gateway() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  install_helm

  # 1. Gateway API standard channel CRDs (HTTPRoute, Gateway, GatewayClass, etc.)
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${gateway_api_version}/standard-install.yaml"
  echo "Gateway API CRDs ${gateway_api_version} installed."

  # 2. Envoy Gateway via OCI Helm registry
  # DaemonSet mode: one Envoy proxy pod per node — no cross-node forwarding,
  # no single-pod SPOF. priorityClassName=system-cluster-critical prevents eviction.
  kubectl create namespace envoy-gateway-system --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version "${envoy_gateway_chart_version}" \
    --namespace envoy-gateway-system \
    --atomic --wait --timeout 5m
  echo "Envoy Gateway ${envoy_gateway_chart_version} installed."

  # 3. EnvoyProxy config: DaemonSet + NodePort service (30080/30443)
  # These NodePorts must match ingress_controller_{http,https}_nodeport and the OCI NLB backends.
  kubectl apply -n envoy-gateway-system -f - << PROXYEOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: proxy-config
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDaemonSet:
        patch:
          type: StrategicMergePatch
          value:
            spec:
              updateStrategy:
                type: RollingUpdate
                rollingUpdate:
                  maxUnavailable: 1
              template:
                spec:
                  priorityClassName: system-cluster-critical
                  resources:
                    requests:
                      cpu: 100m
                      memory: 128Mi
      envoyService:
        type: NodePort
        patch:
          type: MergePatch
          value:
            spec:
              ports:
                - name: http
                  port: 80
                  protocol: TCP
                  nodePort: ${ingress_controller_http_nodeport}
                - name: https
                  port: 443
                  protocol: TCP
                  nodePort: ${ingress_controller_https_nodeport}
PROXYEOF

  # 4. GatewayClass
  kubectl apply -f - << 'GCEOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: proxy-config
    namespace: envoy-gateway-system
GCEOF

  # 5. Gateway: HTTP listener (always) + one HTTPS listener per configured hostname.
  # TLS certs live in envoy-gateway-system (same namespace as Gateway) so no ReferenceGrant needed.
  kubectl apply -n envoy-gateway-system -f - << GWEOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: envoy-gateway-system
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
%{ if argocd_hostname != "" }
    - name: https-argocd
      port: 443
      protocol: HTTPS
      hostname: "${argocd_hostname}"
      tls:
        mode: Terminate
        certificateRefs:
          - name: argocd-server-tls
      allowedRoutes:
        namespaces:
          from: All
%{ endif }
%{ if longhorn_hostname != "" }
    - name: https-longhorn
      port: 443
      protocol: HTTPS
      hostname: "${longhorn_hostname}"
      tls:
        mode: Terminate
        certificateRefs:
          - name: longhorn-frontend-tls
      allowedRoutes:
        namespaces:
          from: All
%{ endif }
GWEOF

  # 6. HTTP → HTTPS redirect HTTPRoute (catch-all on the http listener)
  kubectl apply -n envoy-gateway-system -f - << 'REDIREOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-to-https-redirect
  namespace: envoy-gateway-system
spec:
  parentRefs:
    - name: eg
      namespace: envoy-gateway-system
      sectionName: http
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
REDIREOF

  # 7. TLS policy: TLS 1.2+ and strong cipher suites for all HTTPS listeners
  kubectl apply -n envoy-gateway-system -f - << 'TLSEOF'
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: tls-policy
  namespace: envoy-gateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: eg
  tls:
    minVersion: "1.2"
    ciphers:
      - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
      - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
      - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
      - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
      - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
      - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
TLSEOF

  echo "Envoy Gateway configured: DaemonSet proxy, NodePorts ${ingress_controller_http_nodeport}/${ingress_controller_https_nodeport}."
}

# ── cert-manager ──────────────────────────────────────────────────────────────

install_certmanager() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  install_helm

  helm repo add jetstack https://charts.jetstack.io
  helm repo update

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version "${certmanager_chart_version}" \
    --set crds.enabled=true \
    --set "extraArgs[0]=--feature-gates=ExperimentalGatewayAPISupport=true" \
    --atomic --wait --timeout 5m

  # Bootstrap ClusterIssuers with the correct email address.
  # These are then adoptable by ArgoCD via gitops/cert-manager/ (update email there first).
  # HTTP-01 solver uses Gateway API (gatewayHTTPRoute) — no Ingress controller needed.
  kubectl apply -f - << ISSEOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${certmanager_email_address}
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: eg
                namespace: envoy-gateway-system
                kind: Gateway
ISSEOF

  kubectl apply -f - << ISSEOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${certmanager_email_address}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: eg
                namespace: envoy-gateway-system
                kind: Gateway
ISSEOF
  echo "cert-manager installed with ClusterIssuers (Gateway API HTTP-01 solver). See gitops/cert-manager/ to adopt into ArgoCD."
}

# ── Longhorn ──────────────────────────────────────────────────────────────────

install_longhorn() {
  systemctl enable --now iscsid.service

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  install_helm
  helm repo add longhorn https://charts.longhorn.io
  helm repo update
  helm upgrade --install longhorn longhorn/longhorn \
    --namespace longhorn-system --create-namespace \
    --version "${longhorn_chart_version}" \
    --set "defaultSettings.defaultReplicaCount=3" \
    --set "persistence.defaultClassReplicaCount=3" \
    --atomic --wait --timeout 10m

  echo "Longhorn deployed via Helm ${longhorn_chart_version}."

  %{ if longhorn_hostname != "" }
  # Generate htpasswd hash using openssl (available on Ubuntu 24.04 without extra packages)
  LONGHORN_HASH=$(openssl passwd -apr1 "$${LONGHORN_UI_PASSWORD}")

  kubectl apply -f - << LHEOF
apiVersion: v1
kind: Secret
metadata:
  name: longhorn-basic-auth-secret
  namespace: longhorn-system
type: Opaque
stringData:
  .htpasswd: "${longhorn_ui_username}:$${LONGHORN_HASH}"
---
# SecurityPolicy enforces BasicAuth for the Longhorn HTTPRoute via Envoy Gateway.
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
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: longhorn-frontend
  namespace: longhorn-system
spec:
  parentRefs:
    - name: eg
      namespace: envoy-gateway-system
      sectionName: https-longhorn
  hostnames:
    - ${longhorn_hostname}
  rules:
    - backendRefs:
        - name: longhorn-frontend
          port: 80
---
# TLS cert lives in the Gateway namespace (envoy-gateway-system) — same namespace
# as the Gateway so no ReferenceGrant is needed.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: longhorn-frontend-tls
  namespace: envoy-gateway-system
spec:
  secretName: longhorn-frontend-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - ${longhorn_hostname}
LHEOF
  echo "Longhorn HTTPRoute with BasicAuth created for https://${longhorn_hostname}"
  %{ endif }
}

# ── ArgoCD + Image Updater ────────────────────────────────────────────────────

install_argocd() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  install_helm

  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update

  # server.insecure=true: Envoy Gateway terminates TLS; ArgoCD backend serves plain HTTP.
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --version "${argocd_chart_version}" \
    --set "configs.params.server\.insecure=true" \
    --atomic --wait --timeout 5m

  %{ if argocd_hostname != "" }
  kubectl apply -f - << ARGOEOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  parentRefs:
    - name: eg
      namespace: envoy-gateway-system
      sectionName: https-argocd
  hostnames:
    - ${argocd_hostname}
  rules:
    - backendRefs:
        - name: argocd-server
          port: 80
---
# TLS cert lives in the Gateway namespace (envoy-gateway-system) — same namespace
# as the Gateway so no ReferenceGrant is needed.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-server-tls
  namespace: envoy-gateway-system
spec:
  secretName: argocd-server-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - ${argocd_hostname}
---
# BackendTrafficPolicy: local rate limiting — 100 req/s per source IP (burst-friendly).
# Local mode requires no external rate-limit service; each Envoy proxy pod maintains
# its own counter independently.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: argocd-rate-limit
  namespace: argocd
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: argocd-server
  rateLimit:
    type: Local
    local:
      rules:
        - clientSelectors:
            - remoteAddress:
                type: Distinct
          limit:
            requests: 100
            unit: Second
ARGOEOF
  echo "ArgoCD HTTPRoute created for https://${argocd_hostname}"
  %{ endif }

  # Pre-create grafana-admin secret so kube-prometheus-stack (via ArgoCD) uses generated credentials.
  # The monitoring namespace is created here; ArgoCD will adopt it on first sync.
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n monitoring -f - << GRAFEOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin-secret
  namespace: monitoring
type: Opaque
stringData:
  admin-user: admin
  admin-password: "$${GRAFANA_ADMIN_PASSWORD}"
GRAFEOF
  echo "Grafana admin secret pre-created in monitoring namespace."

  # ── Alertmanager config — created always so kube-prometheus-stack can reference
  # it via alertmanagerSpec.configSecret. Null receiver when OCI Notifications is
  # disabled; OCI webhook receiver when enabled.
%{ if notification_topic_endpoint != "" }
  kubectl apply -n monitoring -f - << AMEOF
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
      - url: '${notification_topic_endpoint}'
        send_resolved: true
AMEOF
%{ else }
  kubectl apply -n monitoring -f - << 'AMEOF'
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
AMEOF
%{ endif }
  echo "Alertmanager config secret created."

  # Bootstrap the App of Apps so ArgoCD self-manages gitops/
  kubectl apply -n argocd -f - << APPEOF
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
    repoURL: ${gitops_repo_url}
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
APPEOF
  echo "ArgoCD App of Apps bootstrapped from ${gitops_repo_url}"
}

# ── kured ─────────────────────────────────────────────────────────────────────

install_kured() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  install_helm
  helm repo add kubereboot https://kubereboot.github.io/charts
  helm repo update
  helm upgrade --install kured kubereboot/kured \
    --version "${kured_chart_version}" \
    --namespace kube-system \
    --set configuration.rebootSentinelFile=/var/run/reboot-required \
    --set configuration.startTime="${kured_start_time}" \
    --set configuration.endTime="${kured_end_time}" \
    --set configuration.rebootDays="{${kured_reboot_days}}" \
    --set configuration.timeZone=UTC \
    --set tolerations[0].key=node-role.kubernetes.io/control-plane \
    --set tolerations[0].operator=Exists \
    --set tolerations[0].effect=NoSchedule \
    --set tolerations[1].key=node-role.kubernetes.io/etcd \
    --set tolerations[1].operator=Exists \
    --set tolerations[1].effect=NoSchedule \
    --atomic --wait --timeout 5m
  echo "kured installed (maintenance window: ${kured_start_time}–${kured_end_time} UTC)."
}

# ── k3s automated upgrades (system-upgrade-controller) ───────────────────────
# Upgrades k3s binaries across all nodes, tracking the configured release channel.
# Servers are upgraded first (k3s-server Plan); agents wait for all servers to
# finish (prepare step references the k3s-server Plan).
#
# Coordination with kured (OS reboots) and unattended-upgrades:
#   - system-upgrade-controller: drains → upgrades k3s binary → uncordons
#   - kured: drains → reboots for kernel update → uncordons
# Both tools drain before acting and run with concurrency=1, so they naturally
# serialise on each node. They address orthogonal concerns (k3s vs kernel).

install_system_upgrade_controller() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  # GitHub provides a stable 'latest' redirect for release assets
  local base="https://github.com/rancher/system-upgrade-controller/releases/latest/download"

  kubectl apply -f "$${base}/crd.yaml"
  kubectl apply -f "$${base}/system-upgrade-controller.yaml"
  kubectl rollout status -n system-upgrade deployment/system-upgrade-controller --timeout=120s

  echo "system-upgrade-controller installed. k3s upgrade Plans are managed via ArgoCD (gitops/system-upgrade/plans.yaml)."
}

# ── k3s installation ──────────────────────────────────────────────────────────

install_k3s_server() {
  local install_params=("--tls-san ${k3s_tls_san}")

%{ if k3s_subnet != "default_route_table" }
  local local_ip flannel_iface
  local_ip=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=src )(\S+)')
  flannel_iface=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=dev )(\S+)')
  install_params+=("--node-ip $local_ip" "--advertise-address $local_ip" "--flannel-iface $flannel_iface")
%{ endif }

%{ if disable_ingress }
  install_params+=("--disable traefik")
%{ else }
  # Always disable k3s built-in Traefik; we install Envoy Gateway instead.
  install_params+=("--disable traefik")
%{ endif }

%{ if expose_kubeapi }
  install_params+=("--tls-san ${k3s_tls_san_public}")
%{ endif }

  local params_str="$${install_params[*]}"
  local max_attempts=10 attempt=0

  if [[ "$IS_FIRST_SERVER" == "true" ]]; then
    echo "==> Bootstrapping new cluster (--cluster-init)"
    until curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="${k3s_version}" K3S_TOKEN="$${K3S_TOKEN}" \
        sh -s - --cluster-init $params_str; do
      attempt=$(( attempt + 1 ))
      [[ $attempt -ge $max_attempts ]] && { echo "ERROR: k3s init failed after $${max_attempts} attempts."; exit 1; }
      echo "  retrying ($${attempt}/$${max_attempts}) ..."
      sleep 15
    done
  else
    echo "==> Joining existing cluster"
    wait_for_kubeapi
    until curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="${k3s_version}" K3S_TOKEN="$${K3S_TOKEN}" \
        sh -s - --server "https://${k3s_url}:6443" $params_str; do
      attempt=$(( attempt + 1 ))
      [[ $attempt -ge $max_attempts ]] && { echo "ERROR: k3s join failed after $${max_attempts} attempts."; exit 1; }
      echo "  retrying ($${attempt}/$${max_attempts}) ..."
      sleep 15
    done
  fi
}

wait_for_cluster_ready() {
  local max=60 attempt=0
  local timeout_seconds=$(( max * 10 ))
  echo "Waiting for all nodes to be Ready (timeout: $${timeout_seconds}s) ..."
  until [[ $(kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null \
               | grep -v " Ready " | wc -l) -eq 0 ]] && \
        [[ $(kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null \
               | wc -l) -gt 0 ]]; do
    attempt=$(( attempt + 1 ))
    [[ $attempt -ge $max ]] && {
      echo "ERROR: cluster not ready after $${timeout_seconds}s. Check /var/log/k3s-cloud-init.log for details."
      kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null || true
      exit 1
    }
    echo "  waiting ($${attempt}/$${max}, $$(( attempt * 10 ))/$${timeout_seconds}s) ..."
    sleep 10
  done
  echo "All nodes are Ready."
}

# ── Main ──────────────────────────────────────────────────────────────────────

bootstrap
configure_unattended_upgrades
install_oci_cli

# Determine first server via IMDSv2 + OCI CLI (bootstraps etcd on first node only)
export OCI_CLI_AUTH=instance_principal
export PATH="/root/bin:$PATH"

INSTANCE_DISPLAY_NAME=$(curl -sfL \
  -H "Authorization: Bearer Oracle" \
  http://169.254.169.254/opc/v2/instance | jq -r '.displayName')

FIRST_SERVER=$(oci compute instance list \
  --compartment-id "${compartment_ocid}" \
  --availability-domain "${availability_domain}" \
  --sort-by TIMECREATED \
  --sort-order ASC 2>/dev/null \
  | jq -re --arg cluster "${cluster_name}" \
      '.data
       | map(select(
           .["freeform-tags"]["k3s-cluster-name"] == $cluster and
           .["freeform-tags"]["k3s-instance-type"] == "k3s-server" and
           (.["lifecycle-state"] | IN("TERMINATED","TERMINATING") | not)
         ))
       | first
       | .["display-name"]' \
  2>/dev/null || echo "")

echo "Election: FIRST_SERVER='$FIRST_SERVER'  SELF='$INSTANCE_DISPLAY_NAME'"

IS_FIRST_SERVER="false"
[[ "$FIRST_SERVER" == "$INSTANCE_DISPLAY_NAME" ]] && IS_FIRST_SERVER="true"

echo "Instance: $INSTANCE_DISPLAY_NAME  First: $IS_FIRST_SERVER"

# ── Resolve cluster secrets (OCI Vault when enabled, else from user-data) ─────

%{ if vault_secret_id_k3s_token != "" }
echo "Fetching k3s token from OCI Vault..."
K3S_TOKEN=$(oci secrets secret-bundle get \
  --secret-id "${vault_secret_id_k3s_token}" \
  --query 'data."secret-bundle-content".content' --raw-output | base64 -d)
%{ else }
K3S_TOKEN="${k3s_token}"
%{ endif }

%{ if vault_secret_id_longhorn_password != "" }
echo "Fetching Longhorn UI password from OCI Vault..."
LONGHORN_UI_PASSWORD=$(oci secrets secret-bundle get \
  --secret-id "${vault_secret_id_longhorn_password}" \
  --query 'data."secret-bundle-content".content' --raw-output | base64 -d)
%{ else }
LONGHORN_UI_PASSWORD="${longhorn_ui_password}"
%{ endif }

%{ if vault_secret_id_grafana_password != "" }
echo "Fetching Grafana admin password from OCI Vault..."
GRAFANA_ADMIN_PASSWORD=$(oci secrets secret-bundle get \
  --secret-id "${vault_secret_id_grafana_password}" \
  --query 'data."secret-bundle-content".content' --raw-output | base64 -d)
%{ else }
GRAFANA_ADMIN_PASSWORD="${grafana_admin_password}"
%{ endif }

install_k3s_server

# Stack installs run only on the first server — all keep the cluster active.
if [[ "$IS_FIRST_SERVER" == "true" ]]; then
  wait_for_cluster_ready

  # Remove the control-plane and etcd NoSchedule taints that k3s ≥ 1.24 adds
  # automatically to server nodes. With only one worker, keeping these taints
  # means user workloads have a single-node SPOF. All four A1.Flex nodes have
  # identical resources (1 OCPU / 6 GB), so co-locating etcd with user workloads
  # is safe for this Always Free topology.
  kubectl taint nodes -l node-role.kubernetes.io/control-plane \
    node-role.kubernetes.io/control-plane:NoSchedule- \
    node-role.kubernetes.io/etcd:NoSchedule- \
    2>/dev/null || true
  echo "Control-plane NoSchedule taints removed — all 4 nodes schedulable."

  install_longhorn

%{ if ! disable_ingress }
  install_envoy_gateway
%{ endif }

  install_certmanager
  install_argocd
%{ if mysql_endpoint != "" }
  # Pre-create MySQL credentials Kubernetes Secret
  kubectl apply -n default -f - << MYSQLEOF
apiVersion: v1
kind: Secret
metadata:
  name: mysql-credentials
  namespace: default
type: Opaque
stringData:
  host: "${mysql_endpoint}"
  username: "${mysql_admin_username}"
  password: "${mysql_admin_password}"
  jdbc-url: "jdbc:mysql://${mysql_endpoint}/${cluster_name}?useSSL=true&requireSSL=true"
MYSQLEOF
  echo "MySQL credentials secret created (host: ${mysql_endpoint})."
%{ endif }
  install_kured
  install_system_upgrade_controller
  echo "==> Stack installed. Network policies and ClusterIssuers are managed via ArgoCD (gitops/)."
fi

echo "==> k3s server cloud-init complete at $(date -u)"
