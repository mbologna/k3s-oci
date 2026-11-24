#!/usr/bin/env bash
# lib/two-phase.sh -- two-phase boot for image-based OSes, whose packages land in a
# new snapshot (transactional-update) or deployment (rpm-ostree) that only becomes
# active after a reboot. Pure bash -- no Terraform interpolation. data.tf adds it
# (and two-phase-done.sh after the entry point) only for OS families with
# local.two_phase; the OS bootstrap's bootstrap() calls two_phase_begin first.
# shellcheck disable=SC2154

K3S_OCI_DIR=/var/lib/k3s-oci
K3S_OCI_UNIT=k3s-oci-bootstrap.service

# two_phase_begin <install_fn>
# Phase 1 (first boot): keep this script, install a unit that runs it again at the
# next boot, call <install_fn> to stage the packages, and reboot. Phase 2 (the unit,
# after the reboot): return at once, and the script carries on with the packages in
# place. A phase 2 that fails leaves the unit enabled, so the next boot retries.
two_phase_begin() {
  local install_fn=$1
  if [[ -f "${K3S_OCI_DIR}/phase1.done" ]]; then
    echo "==> Phase 2: the packages staged in phase 1 are active."
    return 0
  fi

  echo "==> Phase 1: staging packages, then rebooting into them."
  install -d -m 0700 "${K3S_OCI_DIR}"
  # cloud-init runs the script from /var/lib/cloud/instance/scripts/ and only once
  # per instance; Ignition (FCOS) already wrote it to K3S_OCI_DIR. The copy holds
  # what the user-data holds, so root-only like the user-data on disk. The unit runs
  # it through bash: SELinux does not let systemd execute a file labelled var_lib_t.
  if [[ "$(readlink -f "$0")" != "${K3S_OCI_DIR}/bootstrap.sh" ]]; then
    install -m 0700 "$0" "${K3S_OCI_DIR}/bootstrap.sh"
  fi
  cat > "/etc/systemd/system/${K3S_OCI_UNIT}" <<EOF
[Unit]
Description=k3s-oci node bootstrap (runs until it completes once)
Wants=network-online.target
After=network-online.target
ConditionPathExists=!${K3S_OCI_DIR}/done

[Service]
Type=oneshot
# What cloud-init gives the script: Helm and the OCI CLI keep their config in HOME,
# and / is read-only on image-based OSes.
Environment=HOME=/root
WorkingDirectory=/root
ExecStart=/usr/bin/bash ${K3S_OCI_DIR}/bootstrap.sh
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "${K3S_OCI_UNIT}"

  "${install_fn}"

  touch "${K3S_OCI_DIR}/phase1.done"
  echo "==> Phase 1 complete at $(date -u); rebooting."
  # Phase 2's vars header truncates the log; keep phase 1's next to it.
  cp /var/log/k3s-cloud-init.log /var/log/k3s-cloud-init.phase1.log 2>/dev/null || true
  systemctl --no-block reboot
  exit 0
}

# two_phase_k3s_selinux
# For SELinux image-based OSes whose phase 1 stages k3s-selinux. The k3s installer
# must not stage it again (it would skip starting k3s until a reboot), hence
# INSTALL_K3S_SKIP_SELINUX_RPM -- but that also skips the installer's chcon, and the
# binary it moves out of /tmp keeps a tmp label systemd may not execute. The
# policy's file contexts are right, so restorecon fixes the label before every start
# (system-upgrade-controller replaces the binary too), and once for k3s's dirs.
two_phase_k3s_selinux() {
  export INSTALL_K3S_SKIP_SELINUX_RPM=true
  local unit
  for unit in k3s k3s-agent; do
    mkdir -p "/etc/systemd/system/${unit}.service.d"
    printf '[Service]\nExecStartPre=-/usr/sbin/restorecon /usr/local/bin/k3s\n' \
      > "/etc/systemd/system/${unit}.service.d/20-selinux-label.conf"
  done
  mkdir -p /var/lib/rancher /etc/rancher
  restorecon -R /var/lib/rancher /etc/rancher
}
