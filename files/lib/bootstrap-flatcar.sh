#!/usr/bin/env bash
# lib/bootstrap-flatcar.sh -- Flatcar Container Linux (os_family = "flatcar").
# Pure bash. Ignition (nodes.tf) laid down the k3s system extension, merged into
# /usr at boot (/usr/local/bin/k3s, k3s.service), and fetches this script; there
# is nothing to install, so no second phase. /usr is read-only, /etc, /var and
# /opt are writable.
# shellcheck disable=SC2154

bootstrap() {
  # The k3s binary comes from the sysext (Ignition, nodes.tf): make sure it is
  # merged before the script reaches k3s.
  systemd-sysext refresh
  command -v k3s >/dev/null || { echo "ERROR: the k3s system extension is not merged."; exit 1; }
}

# Flatcar updates itself (update_engine, A/B /usr partitions) and Ignition turned
# its own reboots off (REBOOT_STRATEGY=off, locksmithd masked): a timer turns a
# downloaded update into kured's security sentinel, since every Flatcar release
# carries security fixes. k3s patch releases come from systemd-sysupdate, whose
# drop-in (nodes.tf) writes the routine sentinel, /run/reboot-required.
configure_os_updates() {
  mkdir -p /opt/bin
  cat > /opt/bin/k3s-oci-update-sentinel <<'SENTEOF'
#!/bin/sh
# An OS update waits for a reboot: tell kured (gitops/apps/kured.yaml).
if update_engine_client -status 2>/dev/null | grep -q UPDATE_STATUS_UPDATED_NEED_REBOOT; then
  touch /run/security-reboot-required
fi
SENTEOF
  chmod 0755 /opt/bin/k3s-oci-update-sentinel
  cat > /etc/systemd/system/k3s-oci-update-sentinel.service <<'UNITEOF'
[Unit]
Description=Flag a downloaded Flatcar update for kured

[Service]
Type=oneshot
ExecStart=/opt/bin/k3s-oci-update-sentinel
UNITEOF
  cat > /etc/systemd/system/k3s-oci-update-sentinel.timer <<'UNITEOF'
[Unit]
Description=Flag a downloaded Flatcar update for kured

[Timer]
OnBootSec=10min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
UNITEOF
  systemctl daemon-reload
  systemctl enable --now k3s-oci-update-sentinel.timer update-engine.service
}
