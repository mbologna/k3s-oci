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

  # OCI instances only have IPv4 routes; force apt to avoid IPv6 mirror timeouts
  echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

  export DEBIAN_FRONTEND=noninteractive
  # Tolerate partial mirror failures (transient OCI regional mirror issues)
  apt-get update -q || apt-get update -q || true
  apt-get install -y -q --no-install-recommends \
    jq curl python3 python3-pip open-iscsi nfs-common util-linux
  apt-get upgrade -y -q
  apt-get clean
  rm -rf /var/lib/apt/lists/*

  echo "SystemMaxUse=100M"      >> /etc/systemd/journald.conf
  echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf
  systemctl restart systemd-journald
}

# ── Unattended upgrades ───────────────────────────────────────────────────────

configure_unattended_upgrades() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q || apt-get update -q || true
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
// kured handles reboots
Unattended-Upgrade::Automatic-Reboot "false";
UUEOF

  cat > /etc/apt/apt.conf.d/20auto-upgrades << 'UUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
UUEOF

  # Align the apt-daily-upgrade timer with the kured maintenance window so
  # package installation and reboots both happen in the same window.
  # A 60-minute RandomizedDelaySec staggers nodes to avoid simultaneous dpkg locks.
  mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
  cat > /etc/systemd/system/apt-daily-upgrade.timer.d/maintenance-window.conf << TIMEREOF
[Timer]
OnCalendar=
OnCalendar=*-*-* ${kured_start_time}:00
RandomizedDelaySec=60min
TIMEREOF
  systemctl daemon-reload
  systemctl restart apt-daily-upgrade.timer

  systemctl enable --now unattended-upgrades
}

# ── Longhorn prerequisites ────────────────────────────────────────────────────

configure_longhorn_prereqs() {
  systemctl enable --now iscsid.service
  modprobe nfs || true
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
install_k3s_agent

echo "==> k3s agent cloud-init complete at $(date -u)"
