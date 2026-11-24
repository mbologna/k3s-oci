#!/usr/bin/env bash
# lib/bootstrap-opensuse-immutable.sh -- openSUSE Leap Immutable bootstrap for k3s
# server and agent nodes (os_family = "opensuse", opensuse_variant = "immutable").
# Pure bash -- no Terraform interpolation. Prepended to cloud-init scripts by data.tf,
# followed by two-phase.sh: the root filesystem is read-only, packages go into a new
# transactional-update snapshot and are active only after a reboot. /etc, /var,
# /root and /usr/local are writable, so everything else works as on Leap Minimal.
# set -euo pipefail is set by server-vars.sh.tpl / agent-vars.sh.tpl (always prepended first).
# shellcheck disable=SC2154

# Phase 1: what the k3s scripts need and the image lacks, in one snapshot. The image
# already has curl, python3 (with venv, for the OCI CLI) and container-selinux; tar
# unpacks Helm and a custom CA bundle.
# k3s-selinux comes from Rancher's repository, the one the k3s installer would add
# (same infix rule as get.k3s.io). Installed by the installer itself it would land in
# a snapshot of its own and make the installer skip starting k3s until a reboot.
leap_immutable_install() {
  local infix=microos
  # shellcheck disable=SC1091
  [[ "$(. /etc/os-release && echo "${VARIANT_ID:-}")" == "transactional" ]] && infix=slemicro
  cat > /etc/zypp/repos.d/rancher-k3s-common.repo <<EOF
[rancher-k3s-common-stable]
name=Rancher K3s Common (stable)
baseurl=https://rpm.rancher.io/k3s/stable/common/${infix}/noarch
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://rpm.rancher.io/public.key
EOF
  # /var/lib/rpm-state: the policy package's %pre needs it (get.k3s.io creates it too).
  # A zypper exit of 100-103 is success (restart/reboot hints, update stack patched).
  transactional-update --non-interactive run sh -c '
    mkdir -p /var/lib/rpm-state
    zypper --non-interactive --gpg-auto-import-keys install --no-recommends \
      jq tar open-iscsi nfs-client cronie k3s-selinux
    rc=$?; case $rc in 0|10[0-3]) exit 0 ;; *) exit $rc ;; esac'

  # The image updates itself daily (transactional-update.timer, zypper dup) and
  # rebootmgr reboots into the result: both off, configure_unattended_upgrades()
  # patches on the module's schedule and kured reboots.
  systemctl disable --now transactional-update.timer rebootmgr.service 2>/dev/null || true
}

bootstrap() {
  two_phase_begin leap_immutable_install

  # k3s-selinux is in the snapshot from phase 1 (two-phase.sh).
  two_phase_k3s_selinux

  # k3s manages iptables/nftables directly; firewalld would block pod networking.
  systemctl disable --now firewalld.service 2>/dev/null || true

  # etcd snapshot upload schedule (/etc/cron.d, setup_etcd_snapshot_upload).
  systemctl enable --now cron.service

  # Cap journal size to protect the boot volume.
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/10-k3s-size-limit.conf << 'JEOF'
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=100M
JEOF
  systemctl restart systemd-journald

  # The image's cloud-init does not read OCI's ssh_authorized_keys metadata (as on
  # Leap Minimal): write the key for the default user.
  local ssh_dir="/home/${OS_USER}/.ssh"
  mkdir -p "${ssh_dir}"
  echo "${SSH_PUBLIC_KEY}" > "${ssh_dir}/authorized_keys"
  chmod 700 "${ssh_dir}"
  chmod 600 "${ssh_dir}/authorized_keys"
  chown -R "${OS_USER}:users" "${ssh_dir}"

  setup_shared_ssh_host_key
}

configure_unattended_upgrades() {
  # Same schedule and kured contract as Leap Minimal (bootstrap-opensuse.sh): security
  # patches daily at 00:30 UTC, all patches Tue/Wed/Thu at 01:00 UTC, never a reboot
  # of its own. Patches go into a new snapshot; when one was kept, the node must
  # reboot into it, so the helper writes kured's sentinels.
  cat > /usr/local/sbin/tu-patch-with-sentinel << 'PATCHEOF'
#!/bin/sh
# Patch into a new transactional-update snapshot; flag kured when a reboot is due.
# Arguments go to zypper patch (e.g. --category security).
#   --continue: build on the newest snapshot, so a pending one is not discarded.
#   --drop-if-no-change: no snapshot (and no reboot) when nothing was patched.
# Inside the snapshot, a zypper exit of 100-103 is success (restart/reboot hints,
# update stack patched); a second pass applies what 103 deferred.
transactional-update --non-interactive --continue --drop-if-no-change run sh -c '
  for pass in 1 2; do
    zypper --non-interactive --non-interactive-include-reboot-patches patch --auto-agree-with-licenses "$@"
    rc=$?
    case $rc in 103) continue ;; 0|100|101|102) exit 0 ;; *) exit $rc ;; esac
  done' sh "$@" || exit $?

# transactional-update leaves /run/reboot-needed while a new snapshot waits for a
# reboot: kured's stock sentinel, plus the any-night one on the security run
# (gitops/apps/kured.yaml).
if [ -e /run/reboot-needed ]; then
  touch /var/run/reboot-required
  case " $* " in
    *" --category security "*) touch /run/security-reboot-required ;;
  esac
fi
exit 0
PATCHEOF
  chmod 755 /usr/local/sbin/tu-patch-with-sentinel

  cat > /etc/systemd/system/tu-security-patch.service << 'SVCEOF'
[Unit]
Description=Daily security-only patch into a new snapshot
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tu-patch-with-sentinel --category security
SVCEOF

  cat > /etc/systemd/system/tu-security-patch.timer << 'TMREOF'
[Unit]
Description=Run security-only transactional patch daily

[Timer]
OnCalendar=*-*-* 00:30:00 UTC
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
TMREOF

  cat > /etc/systemd/system/tu-full-patch.service << 'SVCEOF'
[Unit]
Description=Weekly patch into a new snapshot (Tue/Wed/Thu)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tu-patch-with-sentinel
SVCEOF

  cat > /etc/systemd/system/tu-full-patch.timer << 'TMREOF'
[Unit]
Description=Run transactional patch Tue/Wed/Thu

[Timer]
OnCalendar=Tue,Wed,Thu *-*-* 01:00:00 UTC
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
TMREOF

  systemctl daemon-reload
  systemctl enable --now tu-security-patch.timer
  systemctl enable --now tu-full-patch.timer
}
