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

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
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
  apt-get update -q
  apt-get install -y -q --no-install-recommends unattended-upgrades apt-listchanges
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
    --set "ports.websecure.tls.enabled=true"
}

# ── cert-manager ──────────────────────────────────────────────────────────────

install_certmanager() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${certmanager_release}/cert-manager.yaml"

  echo "Waiting for cert-manager deployments ..."
  kubectl wait --for=condition=Available deployment \
    --namespace cert-manager --all --timeout=300s

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
          class: traefik
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
          class: traefik
ISSEOF
}

# ── Longhorn ──────────────────────────────────────────────────────────────────

install_longhorn() {
  systemctl enable --now iscsid.service

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  kubectl apply -f "https://raw.githubusercontent.com/longhorn/longhorn/${longhorn_release}/deploy/longhorn.yaml"

  echo "Waiting for Longhorn manager to roll out ..."
  kubectl rollout status daemonset/longhorn-manager \
    --namespace longhorn-system --timeout=300s

  %{ if longhorn_hostname != "" }
  kubectl apply -f - << 'LHEOF'
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
      match: Host(`${longhorn_hostname}`)
      priority: 10
      services:
        - name: longhorn-frontend
          port: 80
  tls:
    secretName: longhorn-frontend-tls
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
  echo "Longhorn IngressRoute created for https://${longhorn_hostname}"
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
    --wait --timeout 5m

  echo "Installing ArgoCD Image Updater ..."
  kubectl apply -n argocd \
    -f "https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/${argocd_image_updater_release}/manifests/install.yaml"

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
      services:
        - name: argocd-server
          port: 80
  tls:
    secretName: argocd-server-tls
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
    --set configuration.rebootDays="${kured_reboot_days}" \
    --set configuration.timeZone=UTC \
    --set tolerations[0].key=node-role.kubernetes.io/control-plane \
    --set tolerations[0].operator=Exists \
    --set tolerations[0].effect=NoSchedule \
    --set tolerations[1].key=node-role.kubernetes.io/etcd \
    --set tolerations[1].operator=Exists \
    --set tolerations[1].effect=NoSchedule
  echo "kured installed (maintenance window: ${kured_start_time}–${kured_end_time} UTC)."
}

# ── Default-deny NetworkPolicy ────────────────────────────────────────────────

apply_network_policies() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  kubectl apply -f - << 'NPEOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: default
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
NPEOF
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
        INSTALL_K3S_VERSION="${k3s_version}" K3S_TOKEN="${k3s_token}" \
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
        INSTALL_K3S_VERSION="${k3s_version}" K3S_TOKEN="${k3s_token}" \
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
  echo "Waiting for cluster to be ready ..."
  until kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get pods -A 2>/dev/null | grep -q Running; do
    attempt=$(( attempt + 1 ))
    [[ $attempt -ge $max ]] && { echo "ERROR: cluster never became ready."; exit 1; }
    echo "  waiting ($${attempt}/$${max}) ..."
    sleep 10
  done
  echo "Cluster is ready."
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
  --lifecycle-state RUNNING \
  --sort-by TIMECREATED \
  --query 'data[?freeformTags."k3s-cluster-name"==`${cluster_name}` && freeformTags."k3s-instance-type"==`k3s-server`].['"'"'display-name'"'"'] | [0][0]' \
  --raw-output 2>/dev/null || echo "")

IS_FIRST_SERVER="false"
[[ "$FIRST_SERVER" == "$INSTANCE_DISPLAY_NAME" ]] && IS_FIRST_SERVER="true"

echo "Instance: $INSTANCE_DISPLAY_NAME  First: $IS_FIRST_SERVER"

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
  install_kured
  apply_network_policies
fi

echo "==> k3s server cloud-init complete at $(date -u)"
