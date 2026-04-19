#!/bin/bash
# k3s-install-server.sh — cloud-init script for k3s control-plane nodes
# Templated by Terraform; $${...} escapes are literal bash, ${...} are Terraform interpolations.

set -euo pipefail

# ── OS detection ──────────────────────────────────────────────────────────────

check_os() {
  local raw_name raw_version
  raw_name=$(grep ^NAME= /etc/os-release | sed 's/NAME=//;s/"//g')
  raw_version=$(grep ^VERSION_ID= /etc/os-release | sed 's/VERSION_ID=//;s/"//g')

  OS_MAJOR="$${raw_version%.*}"
  OS_MINOR="$${raw_version#*.}"

  case "$raw_name" in
    Ubuntu*)               OPERATING_SYSTEM="ubuntu" ;;
    "Oracle Linux Server") OPERATING_SYSTEM="oraclelinux" ;;
    *) echo "Unsupported OS: $raw_name"; exit 1 ;;
  esac

  echo "OS: $OPERATING_SYSTEM  Major: $OS_MAJOR  Minor: $OS_MINOR"
}

# ── Wait for the internal LB to be reachable (non-first nodes only) ───────────

wait_for_kubeapi() {
  local max_attempts=60
  local attempt=0
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

bootstrap_ubuntu() {
  /usr/sbin/netfilter-persistent stop  || true
  /usr/sbin/netfilter-persistent flush || true
  systemctl stop    netfilter-persistent.service || true
  systemctl disable netfilter-persistent.service || true

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q --no-install-recommends software-properties-common jq curl python3 python3-pip
  apt-get upgrade -y -q

  # Cap journal size
  echo "SystemMaxUse=100M"      >> /etc/systemd/journald.conf
  echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf
  systemctl restart systemd-journald

  configure_unattended_upgrades_ubuntu
}

bootstrap_oraclelinux() {
  systemctl disable --now firewalld || true

  echo '(allow iptables_t cgroup_t (dir (ioctl)))' > /root/local_iptables.cil
  semodule -i /root/local_iptables.cil
  setsebool httpd_can_network_connect on -P

  dnf -y update
  dnf -y install jq curl

  configure_dnf_automatic_oraclelinux
}

# ── Unattended upgrades ───────────────────────────────────────────────────────

configure_unattended_upgrades_ubuntu() {
  apt-get install -y -q --no-install-recommends unattended-upgrades apt-listchanges

  cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UUEOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
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

configure_dnf_automatic_oraclelinux() {
  dnf install -y dnf-automatic

  sed -i 's/^apply_updates = no/apply_updates = yes/'          /etc/dnf/automatic.conf
  sed -i 's/^upgrade_type = default/upgrade_type = security/'  /etc/dnf/automatic.conf

  cat > /etc/dnf/automatic-reboot.sh << 'RBEOF'
#!/bin/bash
needs-restarting -r 2>/dev/null || touch /var/run/reboot-required
RBEOF
  chmod +x /etc/dnf/automatic-reboot.sh

  cat > /etc/systemd/system/dnf-automatic-reboot-check.service << 'SVCEOF'
[Unit]
Description=Check if reboot needed after DNF automatic updates
After=dnf-automatic.service
[Service]
Type=oneshot
ExecStart=/etc/dnf/automatic-reboot.sh
SVCEOF

  cat > /etc/systemd/system/dnf-automatic-reboot-check.timer << 'TMREOF'
[Unit]
Description=Run reboot check after dnf-automatic
[Timer]
OnActiveSec=5min
Unit=dnf-automatic-reboot-check.service
[Install]
WantedBy=timers.target
TMREOF

  systemctl daemon-reload
  systemctl enable --now dnf-automatic.timer
  systemctl enable --now dnf-automatic-reboot-check.timer
}

# ── OCI CLI ───────────────────────────────────────────────────────────────────

install_oci_cli_ubuntu() {
  local latest
  latest=$(curl -sfL https://api.github.com/repos/oracle/oci-cli/releases/latest | jq -r '.name')
  bash -c "$(curl -sfL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" \
    -- --accept-all-defaults --oci-cli-version "$latest"
}

install_oci_cli_oraclelinux() {
  if [[ "$OS_MAJOR" -eq 9 ]]; then
    dnf -y install oraclelinux-developer-release-el9 python39-oci-cli python3-jinja2 nginx-all-modules
  else
    dnf -y install oraclelinux-developer-release-el8 python36-oci-cli python3-jinja2 nginx-all-modules
  fi
}

# ── Nginx proxy-protocol reverse proxy ───────────────────────────────────────

install_nginx_proxy() {
  if [[ "$OPERATING_SYSTEM" == "ubuntu" ]]; then
    apt-get install -y -q --no-install-recommends nginx libnginx-mod-stream
    NGINX_MODULE=/usr/lib/nginx/modules/ngx_stream_module.so
    NGINX_USER=www-data
  else
    NGINX_MODULE=/usr/lib64/nginx/modules/ngx_stream_module.so
    NGINX_USER=nginx
  fi
  systemctl enable nginx
}

render_nginx_config() {
  export OCI_CLI_AUTH=instance_principal
  export PATH="/root/bin:$PATH"

  local private_ips=()
  local instance_ocids
  # Filter by cluster name tag so multi-cluster compartments work correctly
  instance_ocids=$(oci search resource structured-search \
    --query-text "QUERY instance resources where lifeCycleState='RUNNING' && freeformTags.key = 'k3s-cluster-name' && freeformTags.value = '${cluster_name}'" \
    --query 'data.items[*].identifier' --raw-output | jq -r '.[]')

  for ocid in $instance_ocids; do
    local private_ip
    private_ip=$(oci compute instance list-vnics --instance-id "$ocid" \
      --raw-output --query 'data[0]."private-ip"' 2>/dev/null || true)
    [[ -n "$private_ip" && "$private_ip" != "null" ]] && private_ips+=("$private_ip")
  done

  local http_upstreams=""
  local https_upstreams=""
  for ip in "$${private_ips[@]}"; do
    http_upstreams+="    server $${ip}:${ingress_controller_http_nodeport} max_fails=3 fail_timeout=10s;"$'\n'
    https_upstreams+="    server $${ip}:${ingress_controller_https_nodeport} max_fails=3 fail_timeout=10s;"$'\n'
  done

  cat > /etc/nginx/nginx.conf << NGINXEOF
load_module $NGINX_MODULE;
user $NGINX_USER;
worker_processes auto;
pid /run/nginx.pid;

events { worker_connections 768; }

stream {
  upstream k3s-http {
$${http_upstreams}  }
  upstream k3s-https {
$${https_upstreams}  }

  log_format basic '\$remote_addr [\$time_local] \$protocol \$status \$bytes_sent \$bytes_received \$session_time "\$upstream_addr"';
  access_log /var/log/nginx/k3s_access.log basic;
  error_log  /var/log/nginx/k3s_error.log;

  proxy_protocol on;

  server { listen ${http_lb_port};  proxy_pass k3s-http;  proxy_next_upstream on; }
  server { listen ${https_lb_port}; proxy_pass k3s-https; proxy_next_upstream on; }
}
NGINXEOF

  nginx -t
  systemctl restart nginx
}

# ── Ingress controllers ───────────────────────────────────────────────────────

install_helm() {
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

render_nginx_ingress_config() {
cat << 'EOF' > "$NGINX_RESOURCES_FILE"
---
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller-loadbalancer
  namespace: ingress-nginx
spec:
  selector:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
  ports:
    - name: http
      port: 80
      protocol: TCP
      targetPort: 80
      nodePort: ${ingress_controller_http_nodeport}
    - name: https
      port: 443
      protocol: TCP
      targetPort: 443
      nodePort: ${ingress_controller_https_nodeport}
  type: NodePort
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/component: controller
data:
  allow-snippet-annotations: "true"
  enable-real-ip: "true"
  proxy-real-ip-cidr: "0.0.0.0/0"
  proxy-body-size: "20m"
  use-proxy-protocol: "true"
EOF
}

install_nginx_ingress() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${nginx_ingress_release}/deploy/static/provider/baremetal/deploy.yaml"
  NGINX_RESOURCES_FILE=/root/nginx-ingress-resources.yaml
  render_nginx_ingress_config
  kubectl apply -f "$NGINX_RESOURCES_FILE"
}

install_traefik2() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  install_helm
  kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -
  helm repo add traefik https://helm.traefik.io/traefik
  helm repo update
  helm upgrade --install --namespace=traefik traefik traefik/traefik \
    --set "service.type=NodePort" \
    --set "ports.web.nodePort=${ingress_controller_http_nodeport}" \
    --set "ports.web.proxyProtocol.trustedIPs[0]=0.0.0.0/0" \
    --set "ports.websecure.nodePort=${ingress_controller_https_nodeport}" \
    --set "ports.websecure.proxyProtocol.trustedIPs[0]=0.0.0.0/0" \
    --set "ports.websecure.tls.enabled=true"
}

install_istio() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  curl -sfL https://istio.io/downloadIstio | ISTIO_VERSION="${istio_release}" sh -
  mv "/istio-${istio_release}" /opt/
  /opt/istio-${istio_release}/bin/istioctl install -y
}

install_ingress() {
  case "${ingress_controller}" in
    nginx)    install_nginx_ingress ;;
    traefik2) install_traefik2 ;;
    istio)    install_istio ;;
    traefik)  echo "Using built-in k3s Traefik — no extra install needed." ;;
    *)        echo "Unknown ingress controller '${ingress_controller}'" ;;
  esac
}

# ── cert-manager ──────────────────────────────────────────────────────────────

install_certmanager() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${certmanager_release}/cert-manager.yaml"

  echo "Waiting for cert-manager deployments to become available ..."
  kubectl wait --for=condition=Available deployment \
    --namespace cert-manager --all --timeout=300s

  # ClusterIssuers — use apply for idempotency
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
          class: nginx
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
          class: nginx
ISSEOF
}

# ── Longhorn ──────────────────────────────────────────────────────────────────

%{ if install_longhorn }
install_longhorn() {
  if [[ "$OPERATING_SYSTEM" == "ubuntu" ]]; then
    apt-get install -y -q --no-install-recommends open-iscsi util-linux
  fi
  systemctl enable --now iscsid.service

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  kubectl apply -f "https://raw.githubusercontent.com/longhorn/longhorn/${longhorn_release}/deploy/longhorn.yaml"
}
%{ endif }

# ── ArgoCD ────────────────────────────────────────────────────────────────────

%{ if install_argocd }
install_argocd() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${argocd_release}/manifests/install.yaml"

  %{ if install_argocd_image_updater }
  kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/${argocd_image_updater_release}/manifests/install.yaml"
  %{ endif }
}
%{ endif }

# ── kured ─────────────────────────────────────────────────────────────────────

%{ if install_kured }
install_kured() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  install_helm
  helm repo add kubereboot https://kubereboot.github.io/charts
  helm repo update
  helm upgrade --install kured kubereboot/kured \
    --version "${kured_release}" \
    --namespace kube-system \
    --set configuration.rebootSentinelFile=/var/run/reboot-required \
    --set tolerations[0].key=node-role.kubernetes.io/control-plane \
    --set tolerations[0].operator=Exists \
    --set tolerations[0].effect=NoSchedule
  echo "kured installed — nodes will reboot one-at-a-time when /var/run/reboot-required exists."
}
%{ endif }

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

  [[ "$OPERATING_SYSTEM" == "oraclelinux" ]] && install_params+=("--selinux")

  local params_str="$${install_params[*]}"
  local max_attempts=10
  local attempt=0

  if [[ "$IS_FIRST_SERVER" == "true" ]]; then
    echo "==> Bootstrapping new cluster (--cluster-init)"
    until curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="${k3s_version}" \
        K3S_TOKEN="${k3s_token}" \
        sh -s - --cluster-init $params_str; do
      attempt=$(( attempt + 1 ))
      [[ $attempt -ge $max_attempts ]] && { echo "ERROR: k3s init failed."; exit 1; }
      echo "  retrying ($${attempt}/$${max_attempts}) ..."
      sleep 15
    done
  else
    echo "==> Joining existing cluster"
    wait_for_kubeapi
    until curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="${k3s_version}" \
        K3S_TOKEN="${k3s_token}" \
        sh -s - --server "https://${k3s_url}:6443" $params_str; do
      attempt=$(( attempt + 1 ))
      [[ $attempt -ge $max_attempts ]] && { echo "ERROR: k3s join failed."; exit 1; }
      echo "  retrying ($${attempt}/$${max_attempts}) ..."
      sleep 15
    done
  fi
}

wait_for_cluster_ready() {
  echo "Waiting for at least one Running pod ..."
  local max=60 attempt=0
  until kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get pods -A 2>/dev/null | grep -q Running; do
    attempt=$(( attempt + 1 ))
    [[ $attempt -ge $max ]] && { echo "ERROR: cluster never became ready."; exit 1; }
    echo "  waiting ($${attempt}/$${max}) ..."
    sleep 10
  done
  echo "Cluster is ready."
}

# ── Main ──────────────────────────────────────────────────────────────────────

check_os

if [[ "$OPERATING_SYSTEM" == "ubuntu" ]]; then
  bootstrap_ubuntu
  %{ if ! disable_ingress }
  install_oci_cli_ubuntu
  %{ endif }
else
  bootstrap_oraclelinux
  %{ if ! disable_ingress }
  install_oci_cli_oraclelinux
  %{ endif }
fi

# Determine if this is the first server in the pool (bootstraps the etcd cluster).
# We identify the "first" instance by TIMECREATED order — the oldest running
# instance whose display name ends with the expected server suffix.
export OCI_CLI_AUTH=instance_principal
export PATH="/root/bin:$PATH"

INSTANCE_DISPLAY_NAME=$(curl -sfL -H "Authorization: Bearer Oracle" \
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

# The following steps run only on the first server to avoid race conditions
if [[ "$IS_FIRST_SERVER" == "true" ]]; then
  wait_for_cluster_ready

  %{ if install_longhorn }
  install_longhorn
  %{ endif }

  %{ if ! disable_ingress }
  %{ if ingress_controller != "traefik" }
  install_ingress
  %{ endif }
  %{ endif }

  %{ if install_certmanager }
  install_certmanager
  %{ endif }

  %{ if install_argocd }
  install_argocd
  %{ endif }

  %{ if install_kured }
  install_kured
  %{ endif }

  %{ if ! disable_ingress }
  install_nginx_proxy
  render_nginx_config
  %{ endif }
fi
