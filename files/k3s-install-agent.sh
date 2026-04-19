#!/bin/bash
# k3s-install-agent.sh — cloud-init for k3s worker nodes (Ubuntu 24.04+)
# Templated by Terraform. Use $${var} for literal bash; Terraform interpolates before upload.
# shellcheck disable=SC2154,SC1083,SC2288,SC2066,SC2034

set -euo pipefail
exec > >(tee /var/log/k3s-cloud-init.log | logger -t k3s-cloud-init) 2>&1

echo "==> k3s agent cloud-init starting at $(date -u)"

# ── OS bootstrap ──────────────────────────────────────────────────────────────

bootstrap() {
  /usr/sbin/netfilter-persistent stop  || true
  /usr/sbin/netfilter-persistent flush || true
  systemctl stop    netfilter-persistent.service || true
  systemctl disable netfilter-persistent.service || true

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q --no-install-recommends \
    jq curl python3 python3-pip open-iscsi nfs-common util-linux
  apt-get upgrade -y -q

  echo "SystemMaxUse=100M"      >> /etc/systemd/journald.conf
  echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf
  systemctl restart systemd-journald
}

# ── Unattended upgrades ───────────────────────────────────────────────────────

configure_unattended_upgrades() {
  apt-get install -y -q --no-install-recommends unattended-upgrades apt-listchanges

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
// kured handles reboots
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

# ── Longhorn prerequisites ────────────────────────────────────────────────────

configure_longhorn_prereqs() {
  systemctl enable --now iscsid.service
  # ensure nfs-common is present (handles RWX volumes)
  modprobe nfs || true
}

# ── OCI CLI ───────────────────────────────────────────────────────────────────

install_oci_cli() {
  local latest
  latest=$(curl -sfL https://api.github.com/repos/oracle/oci-cli/releases/latest | jq -r '.name')
  bash -c "$(curl -sfL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" \
    -- --accept-all-defaults --oci-cli-version "$latest"
}

# ── Nginx proxy-protocol reverse proxy ───────────────────────────────────────

install_nginx_proxy() {
  apt-get install -y -q --no-install-recommends nginx libnginx-mod-stream
  systemctl enable nginx
}

render_nginx_config() {
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

  local http_upstreams="" https_upstreams=""
  for ip in "$${private_ips[@]}"; do
    http_upstreams+="    server $${ip}:${ingress_controller_http_nodeport} max_fails=3 fail_timeout=10s;"$'\n'
    https_upstreams+="    server $${ip}:${ingress_controller_https_nodeport} max_fails=3 fail_timeout=10s;"$'\n'
  done

  cat > /etc/nginx/nginx.conf << NGINXEOF
load_module /usr/lib/nginx/modules/ngx_stream_module.so;
user www-data;
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

# ── k3s agent ─────────────────────────────────────────────────────────────────

install_k3s_agent() {
  local install_params=()

%{ if k3s_subnet != "default_route_table" }
  local local_ip flannel_iface
  local_ip=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=src )(\S+)')
  flannel_iface=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=dev )(\S+)')
  install_params+=("--node-ip $local_ip" "--flannel-iface $flannel_iface")
%{ endif }

  local params_str="$${install_params[*]}"
  local max_attempts=10 attempt=0

  echo "Waiting for k3s API at ${k3s_url}:6443 ..."
  until curl --output /dev/null --silent --insecure "https://${k3s_url}:6443"; do
    attempt=$(( attempt + 1 ))
    [[ $attempt -ge 60 ]] && { echo "ERROR: k3s API unreachable"; exit 1; }
    sleep 10
  done

  attempt=0
  until curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="${k3s_version}" K3S_TOKEN="${k3s_token}" \
      sh -s - agent --server "https://${k3s_url}:6443" $params_str; do
    attempt=$(( attempt + 1 ))
    [[ $attempt -ge $max_attempts ]] && { echo "ERROR: k3s agent install failed after $${max_attempts} attempts."; exit 1; }
    echo "  retrying ($${attempt}/$${max_attempts}) ..."
    sleep 15
  done
}

# ── Main ──────────────────────────────────────────────────────────────────────

bootstrap
configure_unattended_upgrades
configure_longhorn_prereqs

%{ if ! disable_ingress }
install_oci_cli
install_nginx_proxy
%{ endif }

install_k3s_agent

%{ if ! disable_ingress }
render_nginx_config
%{ endif }

echo "==> k3s agent cloud-init complete at $(date -u)"
