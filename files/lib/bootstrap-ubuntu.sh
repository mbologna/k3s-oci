#!/usr/bin/env bash
# lib/bootstrap-ubuntu.sh -- Ubuntu-specific OS bootstrap for k3s server and agent nodes.
# Pure bash -- no Terraform interpolation. Prepended to cloud-init scripts by data.tf.
# Variables (SSH_PUBLIC_KEY, etc.) are exported by the Terraform-rendered vars header.
# set -euo pipefail is set by server-vars.sh.tpl / agent-vars.sh.tpl (always prepended first).
# shellcheck disable=SC2154

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
      echo "Apt lock held for 5 minutes -- killing apt-daily and continuing."
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

  # Stop Ubuntu's apt-daily timers AND services so they don't race with our apt calls.
  # Stopping only services is insufficient — timers would re-trigger them immediately.
  # configure_unattended_upgrades() restarts both timers after we're done.
  systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  wait_apt_lock

  # OCI instances only have IPv4 routes; force apt to avoid IPv6 mirror timeouts
  echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

  export DEBIAN_FRONTEND=noninteractive
  # Tolerate partial mirror failures (transient OCI regional mirror issues)
  apt-get update -q || apt-get update -q || true
  apt-get install -y -q --no-install-recommends \
    software-properties-common jq curl python3 \
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

  # Cap journal size to protect the boot volume.
  # Use a drop-in so this is idempotent on repeated cloud-init runs.
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/10-k3s-size-limit.conf << 'JEOF'
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=100M
JEOF
  systemctl restart systemd-journald

  setup_shared_ssh_host_key
}

configure_unattended_upgrades() {
  export DEBIAN_FRONTEND=noninteractive
  wait_apt_lock
  # Refresh package indices before installing — bootstrap() deleted them at the end
  # to save boot-volume space. Re-fetch now so this function is self-contained and
  # does not depend on the base image having the packages pre-installed.
  apt-get update -q || apt-get update -q || true
  apt-get install -y -q --no-install-recommends unattended-upgrades needrestart
  apt-get clean
  # Do NOT delete indices here — leave them populated so that apt-daily.timer (restarted
  # below) finds them fresh on its first run and security upgrades can apply immediately.

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
// kured handles reboots -- never auto-reboot here
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
  # k3s is excluded -- its lifecycle is managed by the cluster upgrade controller.
  mkdir -p /etc/needrestart/conf.d
  cat > /etc/needrestart/conf.d/99-k3s.conf << 'NREOF'
$nrconf{restart} = 'a';
$nrconf{blacklist_rc} = [qr(^k3s)];
NREOF

  # Override apt-daily-upgrade.timer to run daily at 01:00 UTC (+/-10 min jitter).
  # unattended-upgrade uses 50unattended-upgrades (all security + stable origins).
  # apt.conf.d/ lists are additive — a "security-only" override file in apt.conf.d/
  # appends to, not replaces, the existing origin list, so a separate "security-only"
  # timer cannot be implemented without APT_CONFIG isolation; one daily run is correct.
  # kured manages reboots; needrestart handles in-place daemon restarts above.
  mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
  cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf << 'TIMEREOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 01:00:00 UTC
RandomizedDelaySec=1800
Persistent=true
TIMEREOF

  systemctl daemon-reload
  systemctl restart apt-daily.timer apt-daily-upgrade.timer

  systemctl enable --now unattended-upgrades
}
