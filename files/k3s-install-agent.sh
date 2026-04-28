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
// kured handles reboots
Unattended-Upgrade::Automatic-Reboot "false";
UUEOF

  cat > /etc/apt/apt.conf.d/20auto-upgrades << 'UUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
UUEOF

  # needrestart: automatically restart affected userspace services after package
  # updates (mode 'a' = automatic). CVE patches take effect immediately for
  # running daemons without waiting for the kured reboot window.
  # k3s is excluded — its lifecycle is managed by the cluster upgrade controller.
  mkdir -p /etc/needrestart/conf.d
  cat > /etc/needrestart/conf.d/99-k3s.conf << 'NREOF'
$nrconf{restart} = 'a';
$nrconf{blacklist_rc} = [qr(^k3s)];
NREOF

  # Do NOT pin apt-daily-upgrade to the kured window — patches must install
  # daily so CVE fixes are applied ASAP. Only the reboot is deferred to kured.
  # RandomizedDelaySec staggers nodes to avoid simultaneous dpkg locks.
  mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
  cat > /etc/systemd/system/apt-daily-upgrade.timer.d/stagger.conf << 'TIMEREOF'
[Timer]
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

# ── OCI CLI (for Vault secret fetch when enable_vault = true) ─────────────────
%{ if vault_secret_id_k3s_token != "" }
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
%{ endif }

# ── k3s agent ─────────────────────────────────────────────────────────────────

install_k3s_agent() {
  local install_params=()

%{ if k3s_subnet != "default_route_table" }
  local local_ip flannel_iface
  local_ip=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=src )(\S+)')
  flannel_iface=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=dev )(\S+)')
  install_params+=("--node-ip $local_ip" "--flannel-iface $flannel_iface")
%{ endif }

  local max_api_wait=60 max_attempts=10 attempt=0

  echo "Waiting for k3s API at ${k3s_url}:6443 ..."
  until curl --output /dev/null --silent --insecure "https://${k3s_url}:6443"; do
    attempt=$(( attempt + 1 ))
    [[ $attempt -ge $max_api_wait ]] && { echo "ERROR: k3s API unreachable after $${max_api_wait} attempts."; exit 1; }
    sleep 10
  done

  attempt=0
  until curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="${k3s_version}" K3S_TOKEN="$${K3S_TOKEN}" \
      sh -s - agent --server "https://${k3s_url}:6443" "$${install_params[@]}"; do
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

# ── Resolve k3s token (OCI Vault when enabled, else from user-data) ───────────
%{ if vault_secret_id_k3s_token != "" }
install_oci_cli
export OCI_CLI_AUTH=instance_principal
export PATH="/root/bin:$PATH"
echo "Fetching k3s token from OCI Vault..."
K3S_TOKEN=$(oci secrets secret-bundle get \
  --secret-id "${vault_secret_id_k3s_token}" \
  --query 'data."secret-bundle-content".content' --raw-output | base64 -d)
%{ else }
K3S_TOKEN="${k3s_token}"
%{ endif }

install_k3s_agent

echo "==> k3s agent cloud-init complete at $(date -u)"
