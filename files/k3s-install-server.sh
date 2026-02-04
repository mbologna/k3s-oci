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
  bash -c "$(curl -sfL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" \
    -- --accept-all-defaults --oci-cli-version "${oci_cli_version}"
}

# ── Helm ──────────────────────────────────────────────────────────────────────

install_helm() {
  command -v helm &>/dev/null && return 0
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

# ── Ingress: Traefik 2 (Helm-managed) ────────────────────────────────────────

install_traefik2() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  install_helm
  kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -
  helm repo add traefik https://helm.traefik.io/traefik
  helm repo update
  # OCI NLB uses is_preserve_source=true (transparent mode) — real client IPs arrive directly.
  # No proxy-protocol configuration needed.
  helm upgrade --install --namespace=traefik traefik traefik/traefik \
    --set "service.type=NodePort" \
    --set "ports.web.nodePort=${ingress_controller_http_nodeport}" \
    --set "ports.websecure.nodePort=${ingress_controller_https_nodeport}" \
    --set "ports.websecure.tls.enabled=true" \
    --atomic --wait --timeout 5m
}

# ── cert-manager ──────────────────────────────────────────────────────────────

install_certmanager() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  install_helm

  helm repo add jetstack https://charts.jetstack.io
  helm repo update

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version "${certmanager_release}" \
    --set crds.enabled=true \
    --atomic --wait --timeout 5m

  # Bootstrap ClusterIssuers with the correct email address.
  # These are then adoptable by ArgoCD via gitops/cert-manager/ (update email there first).
  kubectl apply -f - << 'ISSEOF'
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
          ingress:
            ingressClassName: traefik
ISSEOF

  kubectl apply -f - << 'ISSEOF'
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
          ingress:
            ingressClassName: traefik
ISSEOF
  echo "cert-manager installed with ClusterIssuers. See gitops/cert-manager/ to adopt into ArgoCD."
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
    --version "${longhorn_release}" \
    --atomic --wait --timeout 10m

  echo "Longhorn deployed via Helm ${longhorn_release}."

  %{ if longhorn_hostname != "" }
  # Generate htpasswd hash using openssl (available on Ubuntu 24.04 without extra packages)
  LONGHORN_HASH=$(openssl passwd -apr1 "$${LONGHORN_UI_PASSWORD}")

  kubectl apply -f - << LHEOF
apiVersion: v1
kind: Secret
metadata:
  name: longhorn-basicauth
  namespace: longhorn-system
type: Opaque
stringData:
  users: "${longhorn_ui_username}:$${LONGHORN_HASH}"
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: longhorn-basicauth
  namespace: longhorn-system
spec:
  basicAuth:
    secret: longhorn-basicauth
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: longhorn-frontend
  namespace: longhorn-system
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(\`${longhorn_hostname}\`)
      priority: 10
      middlewares:
        - name: longhorn-basicauth
          namespace: longhorn-system
      services:
        - name: longhorn-frontend
          port: 80
  tls:
    secretName: longhorn-frontend-tls
    options:
      name: tls-modern
      namespace: traefik
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: longhorn-frontend-tls
  namespace: longhorn-system
spec:
  secretName: longhorn-frontend-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - ${longhorn_hostname}
LHEOF
  echo "Longhorn IngressRoute with BasicAuth created for https://${longhorn_hostname}"
  %{ endif }
}

# ── ArgoCD + Image Updater ────────────────────────────────────────────────────

install_argocd() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  install_helm

  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update

  # server.insecure=true lets Traefik terminate TLS upstream without double-encryption
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --version "${argocd_chart_release}" \
    --set "configs.params.server\.insecure=true" \
    --atomic --wait --timeout 5m

  echo "Installing ArgoCD Image Updater ..."
  kubectl apply -n argocd \
    -f "https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/${argocd_image_updater_release}/manifests/install.yaml"

  echo "Waiting for ArgoCD Image Updater to roll out ..."
  kubectl rollout status deployment/argocd-image-updater \
    --namespace argocd --timeout=300s

  %{ if argocd_hostname != "" }
  kubectl apply -f - << 'ARGOEOF'
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`${argocd_hostname}`)
      priority: 10
      middlewares:
        - name: argocd-rate-limit
          namespace: argocd
      services:
        - name: argocd-server
          port: 80
  tls:
    secretName: argocd-server-tls
    options:
      name: tls-modern
      namespace: traefik
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-server-tls
  namespace: argocd
spec:
  secretName: argocd-server-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - ${argocd_hostname}
ARGOEOF
  echo "ArgoCD IngressRoute created for https://${argocd_hostname}"
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
    --version "${kured_release}" \
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
  local base="https://github.com/rancher/system-upgrade-controller/releases/download/${system_upgrade_controller_release}"

  kubectl apply -f "$${base}/crd.yaml"
  kubectl apply -f "$${base}/system-upgrade-controller.yaml"
  kubectl rollout status -n system-upgrade deployment/system-upgrade-controller --timeout=120s

  # Plan: upgrade control-plane nodes one at a time
  # Plan: upgrade agent nodes one at a time, only after all servers are done
  kubectl apply -f - << UPGRADEEOF
---
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: k3s-server
  namespace: system-upgrade
spec:
  concurrency: 1
  channel: https://update.k3s.io/v1-release/channels/${k3s_upgrade_channel}
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/control-plane: "true"
  serviceAccountName: system-upgrade
  cordon: true
  drain:
    force: false
    skipWaitForDeleteTimeout: 60
  upgrade:
    image: rancher/k3s-upgrade
---
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: k3s-agent
  namespace: system-upgrade
spec:
  concurrency: 1
  channel: https://update.k3s.io/v1-release/channels/${k3s_upgrade_channel}
  nodeSelector:
    matchExpressions:
      - {key: node-role.kubernetes.io/control-plane, operator: DoesNotExist}
  serviceAccountName: system-upgrade
  cordon: true
  drain:
    force: false
    skipWaitForDeleteTimeout: 60
  prepare:
    image: rancher/k3s-upgrade
    args: ["prepare", "k3s-server"]
  upgrade:
    image: rancher/k3s-upgrade
UPGRADEEOF

  echo "system-upgrade-controller installed, tracking channel: ${k3s_upgrade_channel}"
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
%{ if ingress_controller != "traefik" }
  install_params+=("--disable traefik")
%{ endif }
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
K3S_TOKEN=$(oci secrets secret-bundle get-secret-bundle \
  --secret-id "${vault_secret_id_k3s_token}" \
  --query 'data."secret-bundle-content".content' \
  --raw-output | base64 -d)
%{ else }
K3S_TOKEN="${k3s_token}"
%{ endif }

%{ if vault_secret_id_longhorn_password != "" }
echo "Fetching Longhorn UI password from OCI Vault..."
LONGHORN_UI_PASSWORD=$(oci secrets secret-bundle get-secret-bundle \
  --secret-id "${vault_secret_id_longhorn_password}" \
  --query 'data."secret-bundle-content".content' \
  --raw-output | base64 -d)
%{ else }
LONGHORN_UI_PASSWORD="${longhorn_ui_password}"
%{ endif }

%{ if vault_secret_id_grafana_password != "" }
echo "Fetching Grafana admin password from OCI Vault..."
GRAFANA_ADMIN_PASSWORD=$(oci secrets secret-bundle get-secret-bundle \
  --secret-id "${vault_secret_id_grafana_password}" \
  --query 'data."secret-bundle-content".content' \
  --raw-output | base64 -d)
%{ else }
GRAFANA_ADMIN_PASSWORD="${grafana_admin_password}"
%{ endif }

install_k3s_server

# Stack installs run only on the first server — all keep the cluster active.
if [[ "$IS_FIRST_SERVER" == "true" ]]; then
  wait_for_cluster_ready

  install_longhorn

%{ if ! disable_ingress }
%{ if ingress_controller == "traefik2" }
  install_traefik2
%{ endif }
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
