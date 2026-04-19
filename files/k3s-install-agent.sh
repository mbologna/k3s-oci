#!/bin/bash
# k3s-install-agent.sh — cloud-init script for k3s worker nodes
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
    Ubuntu*)       OPERATING_SYSTEM="ubuntu" ;;
    "Oracle Linux Server") OPERATING_SYSTEM="oraclelinux" ;;
    *)             OPERATING_SYSTEM="unsupported"; echo "Unsupported OS: $raw_name"; exit 1 ;;
  esac

  echo "OS: $OPERATING_SYSTEM  Major: $OS_MAJOR  Minor: $OS_MINOR"
}

# ── Wait for the internal LB kubeapi to be reachable ─────────────────────────

wait_for_kubeapi() {
  local max_attempts=60
  local attempt=0
  echo "Waiting for k3s API at ${k3s_url}:6443 ..."
  until curl --output /dev/null --silent --insecure "https://${k3s_url}:6443"; do
    attempt=$(( attempt + 1 ))
    if [[ $attempt -ge $max_attempts ]]; then
      echo "ERROR: kubeapi not reachable after $${max_attempts} attempts. Aborting."
      exit 1
    fi
    echo "  attempt $${attempt}/$${max_attempts} — sleeping 10s"
    sleep 10
  done
  echo "kubeapi is reachable."
}

# ── OS bootstrap ──────────────────────────────────────────────────────────────

bootstrap_ubuntu() {
  # Disable legacy iptables rules injected by cloud images
  /usr/sbin/netfilter-persistent stop  || true
  /usr/sbin/netfilter-persistent flush || true
  systemctl stop    netfilter-persistent.service || true
  systemctl disable netfilter-persistent.service || true

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q --no-install-recommends software-properties-common jq curl
  apt-get upgrade -y -q

  # Cap journal size to avoid filling the small boot volume
  echo "SystemMaxUse=100M"      >> /etc/systemd/journald.conf
  echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf
  systemctl restart systemd-journald

  configure_unattended_upgrades_ubuntu
}

bootstrap_oraclelinux() {
  systemctl disable --now firewalld || true

  # Fix iptables/SELinux interaction on OL
  echo '(allow iptables_t cgroup_t (dir (ioctl)))' > /root/local_iptables.cil
  semodule -i /root/local_iptables.cil

  dnf -y update
  dnf -y install jq curl

  configure_dnf_automatic_oraclelinux
}

# ── Unattended upgrades / automatic security updates ─────────────────────────

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
// Do NOT auto-reboot — kured handles reboots gracefully
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

  # Apply security updates automatically; leave reboots to kured
  sed -i 's/^apply_updates = no/apply_updates = yes/'           /etc/dnf/automatic.conf
  sed -i 's/^upgrade_type = default/upgrade_type = security/'   /etc/dnf/automatic.conf

  # Create the reboot-required sentinel that kured watches
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
Requires=dnf-automatic.service

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

# ── Nginx proxy-protocol reverse proxy (worker nodes, ingress path) ──────────

install_nginx_proxy() {
  if [[ "$OPERATING_SYSTEM" == "ubuntu" ]]; then
    apt-get install -y -q --no-install-recommends nginx libnginx-mod-stream
    NGINX_MODULE=/usr/lib/nginx/modules/ngx_stream_module.so
    NGINX_USER=www-data
  else
    if [[ "$OS_MAJOR" -eq 9 ]]; then
      dnf -y install oraclelinux-developer-release-el9 nginx-all-modules
    else
      dnf -y module enable nginx:1.20
      dnf -y install oraclelinux-developer-release-el8 nginx-all-modules
    fi
    setsebool httpd_can_network_connect on -P
    NGINX_MODULE=/usr/lib64/nginx/modules/ngx_stream_module.so
    NGINX_USER=nginx
  fi
  systemctl enable nginx
}

render_nginx_config() {
  # Query only instances belonging to THIS cluster using the freeform tag
  export OCI_CLI_AUTH=instance_principal
  export PATH="/root/bin:$PATH"

  local private_ips=()
  local instance_ocids
  instance_ocids=$(oci search resource structured-search \
    --query-text "QUERY instance resources where lifeCycleState='RUNNING' && freeformTags.key = 'k3s-cluster-name' && freeformTags.value = '${cluster_name}'" \
    --query 'data.items[*].identifier' --raw-output | jq -r '.[]')

  for ocid in $instance_ocids; do
    local private_ip
    private_ip=$(oci compute instance list-vnics --instance-id "$ocid" \
      --raw-output --query 'data[0]."private-ip"' 2>/dev/null || true)
    [[ -n "$private_ip" && "$private_ip" != "null" ]] && private_ips+=("$private_ip")
  done

  # Build upstream blocks
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

  server {
    listen ${http_lb_port};
    proxy_pass k3s-http;
    proxy_next_upstream on;
  }
  server {
    listen ${https_lb_port};
    proxy_pass k3s-https;
    proxy_next_upstream on;
  }
}
NGINXEOF

  nginx -t
  systemctl restart nginx
}

install_oci_cli_ubuntu() {
  apt-get install -y -q --no-install-recommends python3 python3-pip
  local latest_ocicli
  latest_ocicli=$(curl -sfL https://api.github.com/repos/oracle/oci-cli/releases/latest | jq -r '.name')
  bash -c "$(curl -sfL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" \
    -- --accept-all-defaults --oci-cli-version "$latest_ocicli"
}

install_oci_cli_oraclelinux() {
  if [[ "$OS_MAJOR" -eq 9 ]]; then
    dnf -y install oraclelinux-developer-release-el9 python39-oci-cli python3-jinja2
  else
    dnf -y install oraclelinux-developer-release-el8 python36-oci-cli python3-jinja2
  fi
}

# ── k3s installation ──────────────────────────────────────────────────────────

install_k3s_agent() {
  local install_params=()

  %{ if k3s_subnet != "default_route_table" }
  local local_ip flannel_iface
  local_ip=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=src )(\S+)')
  flannel_iface=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=dev )(\S+)')
  install_params+=("--node-ip $local_ip" "--flannel-iface $flannel_iface")
  %{ endif }

  [[ "$OPERATING_SYSTEM" == "oraclelinux" ]] && install_params+=("--selinux")

  local params_str="$${install_params[*]}"
  local max_attempts=10
  local attempt=0

  until curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="${k3s_version}" \
      K3S_TOKEN="${k3s_token}" \
      K3S_URL="https://${k3s_url}:6443" \
      sh -s - $params_str; do
    attempt=$(( attempt + 1 ))
    if [[ $attempt -ge $max_attempts ]]; then
      echo "ERROR: k3s agent install failed after $${max_attempts} attempts."
      exit 1
    fi
    echo "k3s install failed (attempt $${attempt}/$${max_attempts}), retrying in 15s ..."
    sleep 15
  done
}

# ── Longhorn prerequisites ────────────────────────────────────────────────────

%{ if install_longhorn }
install_longhorn_prereqs() {
  if [[ "$OPERATING_SYSTEM" == "ubuntu" ]]; then
    apt-get install -y -q --no-install-recommends open-iscsi util-linux
  fi
  systemctl enable --now iscsid.service
}
%{ endif }

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

%{ if install_longhorn }
install_longhorn_prereqs
%{ endif }

wait_for_kubeapi
install_k3s_agent

%{ if ! disable_ingress }
install_nginx_proxy
render_nginx_config
%{ endif }
