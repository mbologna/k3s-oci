#!/usr/bin/env bash
# lib/bootstrap-opensuse.sh -- openSUSE Leap Immutable (os_family = "opensuse").
# Pure bash. cloud-init runs the node script; the root filesystem is read-only, so
# packages go into a new transactional-update snapshot that is active only after a
# reboot (two-phase.sh). /etc, /var, /root and /usr/local stay writable.
# shellcheck disable=SC2154

# Phase 1: what k3s and Longhorn need and the image lacks, in one snapshot.
# k3s-selinux comes from Rancher's repository, the one the k3s installer would add
# (same infix rule as get.k3s.io); installed by the installer itself it would land
# in a snapshot of its own and make the installer skip starting k3s until a reboot.
opensuse_install() {
  local infix=microos
  # shellcheck disable=SC1091
  [[ "$(. /etc/os-release && echo "${VARIANT_ID:-}")" == "transactional" ]] && infix=slemicro
  cat > /etc/zypp/repos.d/rancher-k3s-common.repo <<REPO
[rancher-k3s-common-stable]
name=Rancher K3s Common (stable)
baseurl=https://rpm.rancher.io/k3s/stable/common/${infix}/noarch
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://rpm.rancher.io/public.key
REPO
  # /var/lib/rpm-state: the policy package's %pre needs it (get.k3s.io creates it
  # too). A zypper exit of 100-103 is success (restart/reboot hints).
  transactional-update --non-interactive run sh -c '
    mkdir -p /var/lib/rpm-state
    zypper --non-interactive --gpg-auto-import-keys install --no-recommends \
      tar open-iscsi nfs-client k3s-selinux
    rc=$?; case $rc in 0|10[0-3]) exit 0 ;; *) exit $rc ;; esac'

  # The image updates itself daily (transactional-update.timer, zypper dup) and
  # rebootmgr reboots into the result: both off, configure_os_updates() patches on
  # the module's schedule and kured reboots.
  systemctl disable --now transactional-update.timer rebootmgr.service 2>/dev/null || true
}

bootstrap() {
  two_phase_begin opensuse_install

  # k3s-selinux is in the snapshot from phase 1 (two-phase.sh).
  two_phase_k3s_selinux

  # k3s owns the packet filter; firewalld would block pod networking.
  systemctl disable --now firewalld.service 2>/dev/null || true

  # The image's cloud-init does not read OCI's ssh_authorized_keys metadata.
  if [[ -n "${SSH_PUBLIC_KEY}" ]]; then
    local ssh_dir="/home/${OS_USER}/.ssh"
    mkdir -p "${ssh_dir}"
    echo "${SSH_PUBLIC_KEY}" > "${ssh_dir}/authorized_keys"
    chmod 700 "${ssh_dir}"
    chmod 600 "${ssh_dir}/authorized_keys"
    chown -R "${OS_USER}:users" "${ssh_dir}"
  fi
}

# Security patches daily, all patches Tuesday to Thursday, into a new snapshot;
# never a reboot of its own: kured reboots when a snapshot waits (its sentinels,
# gitops/apps/kured.yaml: a security patch on any night, the rest Tue-Thu).
configure_os_updates() {
  cat > /usr/local/sbin/tu-patch-with-sentinel << 'PATCHEOF'
#!/bin/sh
# Patch into a new transactional-update snapshot; flag kured when a reboot is due.
# Arguments go to zypper patch (e.g. --category security).
#   --continue: build on the newest snapshot, so a pending one is not discarded.
#   --drop-if-no-change: no snapshot (and no reboot) when nothing was patched.
# Inside the snapshot, a zypper exit of 100-103 is success; a second pass applies
# what 103 (the update stack was patched) deferred.
transactional-update --non-interactive --continue --drop-if-no-change run sh -c '
  for pass in 1 2; do
    zypper --non-interactive --non-interactive-include-reboot-patches patch --auto-agree-with-licenses "$@"
    rc=$?
    case $rc in 103) continue ;; 0|100|101|102) exit 0 ;; *) exit $rc ;; esac
  done' sh "$@" || exit $?

# transactional-update leaves /run/reboot-needed while a new snapshot waits.
if [ -e /run/reboot-needed ]; then
  touch /var/run/reboot-required
  case " $* " in
    *" --category security "*) touch /run/security-reboot-required ;;
  esac
fi
exit 0
PATCHEOF
  chmod 755 /usr/local/sbin/tu-patch-with-sentinel

  local name args calendar
  for name in security full; do
    if [[ "${name}" == "security" ]]; then
      args="--category security"; calendar="*-*-* 00:30:00 UTC"
    else
      args=""; calendar="Tue,Wed,Thu *-*-* 01:00:00 UTC"
    fi
    cat > "/etc/systemd/system/tu-${name}-patch.service" <<SVCEOF
[Unit]
Description=transactional-update: ${name} patches into a new snapshot
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tu-patch-with-sentinel ${args}
SVCEOF
    cat > "/etc/systemd/system/tu-${name}-patch.timer" <<TMREOF
[Unit]
Description=transactional-update: ${name} patches

[Timer]
OnCalendar=${calendar}
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
TMREOF
  done
  systemctl daemon-reload
  systemctl enable --now tu-security-patch.timer tu-full-patch.timer
}
