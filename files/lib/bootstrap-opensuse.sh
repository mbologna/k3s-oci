#!/usr/bin/env bash
# lib/bootstrap-opensuse.sh -- openSUSE-specific OS bootstrap for k3s server and agent nodes.
# Pure bash -- no Terraform interpolation. Prepended to cloud-init scripts by data.tf.
# Variables (SSH_PUBLIC_KEY, etc.) are exported by the Terraform-rendered vars header.
# set -euo pipefail is set by server-vars.sh.tpl / agent-vars.sh.tpl (always prepended first).
# shellcheck disable=SC2154

bootstrap() {
  # Stop and permanently disable firewalld — k3s manages iptables/nftables directly
  # via flannel. An active firewalld would block pod networking and NodePorts.
  # Equivalent of Ubuntu disabling netfilter-persistent.
  systemctl stop    firewalld.service 2>/dev/null || true
  systemctl disable firewalld.service 2>/dev/null || true

  # Permanently disable the zypper auto-refresh timer so it never races with our
  # patch timers. Using disable+stop is more reliable than stop alone (survives reboots).
  systemctl disable --now zypper-refresh.service 2>/dev/null || true
  systemctl disable --now zypper-refresh.timer   2>/dev/null || true

  # Refresh repos and install k3s prerequisites.
  # openSUSE package equivalents:
  #   nfs-common   → nfs-client     (provides nfsstat, mount.nfs, etc.)
  #   open-iscsi   → open-iscsi     (same package name)
  #   util-linux   → util-linux     (same package name, usually pre-installed)
  zypper --non-interactive refresh || zypper --non-interactive refresh || true
  zypper --non-interactive install --no-recommends \
    jq curl python3 open-iscsi nfs-client util-linux

  # Lock the kernel package so zypper patch cannot install a new kernel during
  # cloud-init. kured + system-upgrade-controller manage planned kernel upgrades.
  zypper addlock kernel-default || true

  # Cap journal size to protect the boot volume.
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/10-k3s-size-limit.conf << 'JEOF'
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=100M
JEOF
  systemctl restart systemd-journald

  # Belt-and-suspenders SSH key injection: ensure the key is present even if
  # cloud-init's Oracle datasource doesn't inject it into the default user's
  # authorized_keys (behaviour differs across image versions).
  local ssh_dir="/home/${OS_USER}/.ssh"
  mkdir -p "${ssh_dir}"
  echo "${SSH_PUBLIC_KEY}" > "${ssh_dir}/authorized_keys"
  chmod 700 "${ssh_dir}"
  chmod 600 "${ssh_dir}/authorized_keys"
  chown -R "${OS_USER}:users" "${ssh_dir}"

  setup_shared_ssh_host_key
}

configure_unattended_upgrades() {
  # Security-only zypper patch service + timer at 00:30 UTC (+/-30 min jitter).
  # Applies security patches only (zypper --category security).
  # Never auto-reboots — kured manages the reboot window via /var/run/reboot-required.
  #
  # zypper patch exit codes:
  #   0   = success, no reboot/restart needed
  #   100 = success, some running processes need restart (no reboot)
  #   102 = success, kernel or firmware updated — reboot required
  #   103 = package-manager patch installed; re-run to apply remaining patches
  #   any other non-zero = error
  #
  # On exit 102: create /var/run/reboot-required so kured's default sentinel
  #   (--reboot-sentinel /var/run/reboot-required) triggers the drain-reboot-uncordon cycle.
  # On exit 100: restart affected userspace services, excluding k3s (needrestart equivalent).
  #   k3s lifecycle is managed by the cluster upgrade controller.
  #
  # Zypp lock contention: if another zypper process holds the lock, wait up to 5 min.
  # zypper --non-interactive already handles this internally (ZYPPER_EXIT_ZYPP_LOCKED=7)
  # but we add an explicit retry for robustness across zypper versions.

  # Helper script called by both patch services.
  cat > /usr/local/sbin/zypper-patch-with-sentinel << 'PATCHEOF'
#!/bin/sh
# Run zypper patch, create kured sentinel on reboot-required, restart services on restart-required.
# Do NOT use set -e: zypper returns non-zero exit codes for informational states (100, 102).

# Retry on zypp lock (exit 7) up to 5 minutes.
waited=0
while true; do
  rc=0
  zypper --non-interactive patch "$@" --auto-agree-with-licenses || rc=$?
  [ "$rc" -ne 7 ] && break
  if [ "$waited" -ge 300 ]; then
    echo "zypp lock held for 5 minutes — aborting." >&2
    exit 7
  fi
  echo "zypp locked, retrying in 10s..."
  sleep 10
  waited=$((waited + 10))
done

case "$rc" in
  0)
    # No restart or reboot needed.
    ;;
  100)
    # Restart affected userspace services (needrestart equivalent).
    # zypper ps lists processes using stale files; extract service names from the table, skip k3s.
    zypper ps 2>/dev/null \
      | awk -F'|' 'NR>2 && $6 ~ /\.service$/ { gsub(/ /,"",$6); print $6 }' \
      | grep -v '^k3s' \
      | sort -u \
      | xargs -r systemctl try-restart 2>/dev/null || true
    ;;
  102)
    # Restart affected services first, then flag for kured reboot.
    zypper ps 2>/dev/null \
      | awk -F'|' 'NR>2 && $6 ~ /\.service$/ { gsub(/ /,"",$6); print $6 }' \
      | grep -v '^k3s' \
      | sort -u \
      | xargs -r systemctl try-restart 2>/dev/null || true
    touch /var/run/reboot-required
    ;;
  103)
    # Package-manager patch was installed; re-run once to apply remaining patches.
    # zypper exit 103 = ZYPPER_EXIT_INF_RESTART_NEEDED (not an error — informational).
    zypper --non-interactive patch "$@" --auto-agree-with-licenses || rc=$?
    case "$rc" in
      0|100|102) : ;;
      *) exit "$rc" ;;
    esac
    ;;
  *)
    exit "$rc"
    ;;
esac
exit 0
PATCHEOF
  chmod 755 /usr/local/sbin/zypper-patch-with-sentinel

  cat > /etc/systemd/system/zypper-security-patch.service << 'SVCEOF'
[Unit]
Description=Daily security-only zypper patch
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zypper-patch-with-sentinel --category security
SVCEOF

  cat > /etc/systemd/system/zypper-security-patch.timer << 'TMREOF'
[Unit]
Description=Run security-only zypper patch daily

[Timer]
OnCalendar=*-*-* 00:30:00 UTC
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
TMREOF

  # Non-security upgrades: Tue/Wed/Thu at 01:00 UTC (+/-10 min jitter).
  cat > /etc/systemd/system/zypper-full-patch.service << 'SVCEOF'
[Unit]
Description=Weekly non-security zypper patch (Tue/Wed/Thu)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zypper-patch-with-sentinel
SVCEOF

  cat > /etc/systemd/system/zypper-full-patch.timer << 'TMREOF'
[Unit]
Description=Run full zypper patch Tue/Wed/Thu

[Timer]
OnCalendar=Tue,Wed,Thu *-*-* 01:00:00 UTC
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
TMREOF

  systemctl daemon-reload
  systemctl enable --now zypper-security-patch.timer
  systemctl enable --now zypper-full-patch.timer
}
