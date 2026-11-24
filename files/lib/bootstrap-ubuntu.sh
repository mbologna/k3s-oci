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

  # Ubuntu kernels from 7.0.0-41 combine apparmor_restrict_unprivileged_unconfined=1
  # (the 26.04 default) with runc's change into a stacked AppArmor label, which
  # containerd's profile doesn't accept as a signal peer: containers can no longer
  # signal their own threads (.NET and bun apps crashed). Set before k3s starts any
  # container. Remove once k3s ships a containerd with the fix
  # (containerd/containerd#14485). A kernel without the key just logs an error.
  cat > /etc/sysctl.d/91-k3s-apparmor.conf << 'AAEOF'
kernel.apparmor_restrict_unprivileged_unconfined=0
AAEOF
  sysctl -p /etc/sysctl.d/91-k3s-apparmor.conf || true

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
    "${distro_id}:${distro_codename}-updates";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
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

  # security-reboot-check: Ubuntu sets /var/run/reboot-required for any package
  # that asks for a reboot, security fix or not. This writes
  # /run/security-reboot-required, which kured reboots for on any night (the
  # stock flag waits for Tuesday to Thursday, gitops/apps/kured.yaml), when a
  # package in /run/reboot-required.pkgs has its installed version published in
  # a -security pocket, and removes it otherwise. /run empties at boot.
  cat > /usr/local/sbin/security-reboot-check << 'SRCEOF'
#!/usr/bin/python3
"""Flag a pending reboot that installs a security fix (k3s-oci)."""
import re
import subprocess
from pathlib import Path

REQUIRED = Path("/run/reboot-required")
PKGS = Path("/run/reboot-required.pkgs")
SENTINEL = Path("/run/security-reboot-required")


def from_security(pkg):
    """True if the installed version of pkg is published in a -security pocket."""
    out = subprocess.run(["apt-cache", "policy", pkg], capture_output=True, text=True).stdout
    installed = re.search(r"^\s+Installed: (\S+)", out, re.M)
    version, security = None, set()
    for line in out.splitlines():
        if line.startswith(" *** ") or (line.startswith("     ") and line[5:6] not in ("", " ")):
            version = line[5:].split()[0]
        elif version and "-security" in line:
            security.add(version)
    return bool(installed) and installed[1] in security


pkgs = sorted(set(PKGS.read_text().split())) if REQUIRED.exists() and PKGS.exists() else []
reasons = [f"{p}: security update" for p in pkgs if from_security(p)]
if reasons:
    SENTINEL.write_text("\n".join(reasons) + "\n")
    print("security reboot needed:", "; ".join(reasons))
else:
    SENTINEL.unlink(missing_ok=True)
    print("no security reboot needed" + (" (reboot-required ignored)" if REQUIRED.exists() else ""))
SRCEOF
  chmod 755 /usr/local/sbin/security-reboot-check

  cat > /etc/systemd/system/security-reboot-check.service << 'SRCEOF'
[Unit]
Description=Flag a pending reboot that installs a security fix (for kured)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/security-reboot-check
SRCEOF
  # Hourly, for package runs outside the timer (a manual apt upgrade).
  cat > /etc/systemd/system/security-reboot-check.timer << 'SRCEOF'
[Unit]
Description=Refresh /run/security-reboot-required hourly

[Timer]
OnCalendar=hourly
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
SRCEOF
  # And right after the nightly package run, so the flag is there for kured's
  # window that same night.
  mkdir -p /etc/systemd/system/apt-daily-upgrade.service.d
  cat > /etc/systemd/system/apt-daily-upgrade.service.d/security-reboot-check.conf << 'SRCEOF'
[Service]
ExecStartPost=-/usr/local/sbin/security-reboot-check
SRCEOF

  # Override apt-daily-upgrade.timer to run daily at 01:00 UTC (0–30 min jitter; RandomizedDelaySec=1800).
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

  # apt-daily.service (apt-get update) is Type=oneshot, so its start timeout is
  # infinite. An update hung in its HTTP fetch stayed "activating" for 26 days on a
  # node: the timers never fired again, the lists lock stayed held and patching
  # silently stopped, which looks like "no reboot needed" to kured. Cap it so the
  # next run starts fresh. apt-daily-upgrade (dpkg) is not capped: killing dpkg
  # mid-install is worse than waiting.
  mkdir -p /etc/systemd/system/apt-daily.service.d
  cat > /etc/systemd/system/apt-daily.service.d/timeout.conf << 'ADEOF'
[Service]
TimeoutStartSec=1h
ADEOF

  # unattended-upgrade-shutdown holds a logind delay lock until logind signals a
  # shutdown, and the subscription is lost when logind restarts (needrestart
  # restarts it after a systemd upgrade). A kured reboot then waited the full
  # InhibitDelayMaxSec on the orphaned lock. PartOf restarts it with logind.
  mkdir -p /etc/systemd/system/unattended-upgrades.service.d
  cat > /etc/systemd/system/unattended-upgrades.service.d/partof-logind.conf << 'UUEOF'
[Unit]
PartOf=systemd-logind.service
UUEOF

  systemctl daemon-reload
  systemctl restart apt-daily.timer apt-daily-upgrade.timer
  systemctl enable --now security-reboot-check.timer

  systemctl enable --now unattended-upgrades

  # Release the kernel hold that bootstrap() set to prevent mid-provisioning
  # kernel upgrades. With k3s running and kured managing reboots, unattended-upgrades
  # can safely apply kernel security updates — kured will reboot in its window.
  apt-mark unhold linux-oracle linux-image-oracle linux-headers-oracle 2>/dev/null || true
}
