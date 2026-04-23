#!/usr/bin/env bash
# lib/common.sh — shared OS bootstrap functions for k3s server and agent nodes.
# Pure bash — no Terraform interpolation. Sourced by prepending to cloud-init scripts.
# Variables (K3S_VERSION, VAULT_SECRET_ID_K3S_TOKEN, etc.) are exported by
# the Terraform-rendered vars header (server-vars.sh.tpl / agent-vars.sh.tpl).
# shellcheck disable=SC2154

# ── OS bootstrap ──────────────────────────────────────────────────────────────

# Wait for apt/dpkg locks so our apt calls never race with apt-daily or
# unattended-upgrades that Ubuntu starts automatically on first boot.
wait_apt_lock() {
  local lockfiles=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/cache/apt/archives/lock
    /var/lib/apt/lists/lock
  )
  local waited=0
  while fuser "${lockfiles[@]}" &>/dev/null 2>&1; do
    if (( waited == 0 )); then
      echo "Waiting for apt/dpkg lock to be released..."
    fi
    sleep 5
    (( waited += 5 ))
    if (( waited >= 300 )); then
      echo "Apt lock held for 5 minutes — killing apt-daily and continuing."
      systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
      sleep 3
      break
    fi
  done
}

bootstrap() {
  /usr/sbin/netfilter-persistent stop  || true
  /usr/sbin/netfilter-persistent flush || true
  systemctl stop    netfilter-persistent.service || true
  systemctl disable netfilter-persistent.service || true

  # Stop Ubuntu's apt-daily timer so it doesn't race with our apt calls.
  # configure_unattended_upgrades() will re-enable it after we're done.
  systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  wait_apt_lock

  # OCI instances only have IPv4 routes; force apt to avoid IPv6 mirror timeouts
  echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

  export DEBIAN_FRONTEND=noninteractive
  # Tolerate partial mirror failures (transient OCI regional mirror issues)
  apt-get update -q || apt-get update -q || true
  apt-get install -y -q --no-install-recommends \
    software-properties-common jq curl python3 python3-pip \
    open-iscsi nfs-common util-linux
  # Hold the oracle kernel packages so that apt-get upgrade or unattended-upgrades
  # cannot install a newer kernel during cloud-init. A new kernel would become the
  # grub default and the machine would reboot into it on the next boot, potentially
  # hitting regressions (e.g. 6.17.0-1010 boot loop on OCI A1.Flex).
  # kured + system-upgrade-controller manage planned kernel upgrades.
  apt-mark hold linux-oracle linux-image-oracle linux-headers-oracle || true
  # Security and package upgrades are deferred to unattended-upgrades on its
  # daily schedule so that the cluster is healthy before any OS changes land.
  # Never run apt-get upgrade here: it would install the held kernel and trigger
  # a reboot into a potentially broken kernel, causing a boot loop.
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
  wait_apt_lock
  apt-get update -q || apt-get update -q || true
  apt-get install -y -q --no-install-recommends unattended-upgrades apt-listchanges needrestart
  apt-get clean
  rm -rf /var/lib/apt/lists/*

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
  # updates (mode 'a' = automatic). CVE patches take effect immediately for
  # running daemons without waiting for the kured reboot window.
  # k3s is excluded — its lifecycle is managed by the cluster upgrade controller.
  mkdir -p /etc/needrestart/conf.d
  cat > /etc/needrestart/conf.d/99-k3s.conf << 'NREOF'
$nrconf{restart} = 'a';
$nrconf{blacklist_rc} = [qr(^k3s)];
NREOF

  # Do NOT pin apt-daily-upgrade to the kured maintenance window.
  # Patches must install on Ubuntu's default daily schedule so CVE fixes are
  # applied ASAP. Only the reboot is deferred to kured.
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

# ── OCI CLI ───────────────────────────────────────────────────────────────────
# Always installed on server nodes (required for first-server election via
# instance_principal auth). Installed on agent nodes only when Vault is enabled.

install_oci_cli() {
  if /root/bin/oci --version &>/dev/null 2>&1; then
    echo "OCI CLI already installed, skipping."
    return 0
  fi
  bash -c "$(curl -sfL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" \
    -- --accept-all-defaults
  # Suppress announcements so they never pollute stdout of subsequent oci commands
  # (announcements on stdout break pipes to jq / base64). Use python3 to set the
  # key idempotently in [OCI_CLI_SETTINGS] rather than blindly appending.
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

# ── Network helpers ───────────────────────────────────────────────────────────
# Resolve node IP and flannel interface from K3S_SUBNET when a specific subnet
# CIDR is provided. Sets LOCAL_IP and FLANNEL_IFACE in the caller's scope.
# Used by both server and agent install functions.

resolve_flannel_params() {
  if [[ "${K3S_SUBNET}" != "default_route_table" ]]; then
    export LOCAL_IP
    export FLANNEL_IFACE
    LOCAL_IP=$(ip -4 route ls "${K3S_SUBNET}" | grep -Po '(?<=src )(\S+)')
    FLANNEL_IFACE=$(ip -4 route ls "${K3S_SUBNET}" | grep -Po '(?<=dev )(\S+)')
  fi
}
