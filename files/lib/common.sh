#!/usr/bin/env bash
# lib/common.sh -- OS-independent helpers of the node script. Pure bash: the
# Terraform-rendered header (node-vars.sh.tpl) exports the variables.
# shellcheck disable=SC2154

# -- Longhorn prerequisites ----------------------------------------------------

configure_longhorn_prereqs() {
  # Stale iSCSI sessions: Longhorn opens a session per volume to the pod IP of
  # the current replica. When that replica moves (an instance-manager restart,
  # a k3s upgrade), the old session keeps reconnecting to an IP that is gone,
  # and iscsid refuses to log it out mid-reconnect. With the stock
  # replacement_timeout of 6000 s (100 min) the volume can't attach on its new
  # engine for that long; a PVC stayed "attaching" for over an hour. 120 s lets
  # the dead session go so the new one takes over.
  if grep -q '^node.session.timeo.replacement_timeout' /etc/iscsi/iscsid.conf 2>/dev/null; then
    sed -i 's/^node.session.timeo.replacement_timeout.*/node.session.timeo.replacement_timeout = 120/' \
      /etc/iscsi/iscsid.conf
  else
    echo 'node.session.timeo.replacement_timeout = 120' >>/etc/iscsi/iscsid.conf
  fi

  # Keep multipathd off Longhorn volumes: every Longhorn iSCSI disk reports the
  # same vendor/product (IET VIRTUAL-DISK) and WWID. With find_multipaths "on"
  # (Ubuntu's default) multipathd takes two attached Longhorn volumes for two
  # paths to one LUN and from then on wraps each new one in an mpath device;
  # the CSI mount of the raw device then fails ("already mounted or mount
  # point busy") and the pod hangs in ContainerCreating. The OCI boot volume is
  # not multipathed, so blacklisting only Longhorn's disks changes nothing
  # else. A conf.d drop-in leaves the distribution's multipath.conf alone.
  mkdir -p /etc/multipath/conf.d
  cat >/etc/multipath/conf.d/longhorn.conf <<'EOF'
# Written by k3s-oci cloud-init: keep multipathd off Longhorn's iSCSI disks.
blacklist {
    device {
        vendor "IET"
        product "VIRTUAL-DISK"
    }
}
EOF
  if systemctl is-active --quiet multipathd.service; then
    systemctl reload multipathd.service || systemctl restart multipathd.service || true
  fi

  systemctl enable iscsid.service
  systemctl restart iscsid.service
  modprobe nfs || true
}

# -- k3s memory protection -----------------------------------------------------
# A drop-in for the k3s unit, written before the installer creates and starts
# it, so the first start already has it. MemoryLow protects the unit's memory
# (k3s, its shims and the page cache it uses) from
# reclaim while other cgroups still have reclaimable memory: under pressure the
# kernel takes pods' cache before stalling k3s. GOMEMLIMIT is a soft cap that
# makes Go collect harder before its heap grows past it; it never kills k3s: past
# the limit Go keeps collecting, capped at half the CPU.

setup_k3s_memory_protection() {
  mkdir -p /etc/systemd/system/k3s.service.d
  printf '[Service]\nMemoryLow=1536M\nEnvironment=GOMEMLIMIT=1700MiB\n' \
    > /etc/systemd/system/k3s.service.d/10-memory.conf
  # fwupd updates firmware on physical machines; an OCI VM has none, and the
  # daemon holds 70-90 MiB.
  systemctl mask --now fwupd.service fwupd-refresh.timer 2>/dev/null || true
}

# -- flannel VXLAN FDB self-heal -----------------------------------------------
# A missing flannel.1 forwarding-database entry silently drops outbound VXLAN
# traffic: routing and DNAT succeed locally, the packet never leaves the node.
# It broke DNS for every pod on a cluster built from this module, and the kernel
# doesn't reliably rebuild the entry. A timer re-applies each peer's entry
# every 5 minutes, idempotently. Peers come from the flannel node annotations
# (VtepMAC in backend-data, underlay IP in public-ip), read with k3s's embedded
# flannel kubeconfig, which exists on servers and agents and may list nodes.

setup_flannel_fdb_fix() {
  mkdir -p /var/lib/k3s-oci/bin
  cat >/var/lib/k3s-oci/bin/flannel-fdb-fix.sh <<'EOF'
#!/bin/sh
# Written by the k3s-oci node script: re-apply missing flannel.1 FDB entries.
set -eu
KC=/var/lib/rancher/k3s/agent/k3scontroller.kubeconfig
# The kubectl k3s already unpacked: `k3s kubectl` from a freshly upgraded binary
# first unpacks its own data dir, which this sandbox can't write. current/ moves
# only once the new k3s has started.
KUBECTL=/var/lib/rancher/k3s/data/current/bin/kubectl
[ -x "$KUBECTL" ] || KUBECTL="k3s kubectl"
# Consecutive failed lookups, kept across runs: a k3s restart (an upgrade, a
# crash) takes the API away for minutes and shouldn't fail the unit; a lookup
# still failing after 6 runs (30 min) should.
FAILS=/run/flannel-fdb-fix/failures
ip link show flannel.1 >/dev/null 2>&1 || { echo "flannel-fdb-fix: flannel.1 not found, skipping" >&2; exit 0; }
[ -r "$KC" ] || { echo "flannel-fdb-fix: $KC not found, skipping" >&2; exit 0; }
SELF_MAC=$(cat /sys/class/net/flannel.1/address)
# Captured first: in a pipeline a kubectl failure would go unnoticed (no pipefail in sh).
if ! PEERS=$($KUBECTL --kubeconfig "$KC" get nodes -o jsonpath='{range .items[*]}{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip} {.metadata.annotations.flannel\.alpha\.coreos\.com/backend-data}{"\n"}{end}'); then
    n=$(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 ))
    echo "$n" >"$FAILS"
    [ "$n" -ge 6 ] && { echo "flannel-fdb-fix: cannot list nodes, $n runs in a row" >&2; exit 1; }
    echo "flannel-fdb-fix: cannot list nodes (run $n of 6 before failing), skipping" >&2
    exit 0
fi
rm -f "$FAILS"
printf '%s\n' "$PEERS" | while read -r ip data; do
    mac=$(printf '%s' "$data" | sed -n 's/.*"VtepMAC":"\([^"]*\)".*/\1/p')
    [ -n "$ip" ] && [ -n "$mac" ] && [ "$mac" != "$SELF_MAC" ] || continue
    if bridge fdb show dev flannel.1 | grep -qi "^$mac dst $ip "; then
        echo "flannel-fdb-fix: $mac dst $ip already present"
    else
        bridge fdb replace "$mac" dst "$ip" dev flannel.1
        echo "flannel-fdb-fix: added missing entry $mac dst $ip"
    fi
done
EOF
  chmod 0755 /var/lib/k3s-oci/bin/flannel-fdb-fix.sh

  cat >/etc/systemd/system/flannel-fdb-fix.service <<'EOF'
[Unit]
Description=Re-apply missing flannel VXLAN FDB entries (idempotent)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# Through sh: SELinux does not let systemd execute a file labelled var_lib_t.
ExecStart=/bin/sh /var/lib/k3s-oci/bin/flannel-fdb-fix.sh
# It only reads the node list through the API and rewrites flannel.1's FDB over
# netlink: CAP_NET_ADMIN and a throwaway kubectl cache are all it needs.
Environment=KUBECACHEDIR=/tmp/kube-cache
# The script's failure counter; kept between runs.
RuntimeDirectory=flannel-fdb-fix
RuntimeDirectoryPreserve=yes
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
PrivateDevices=true
CapabilityBoundingSet=CAP_NET_ADMIN
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
MemoryDenyWriteExecute=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
SystemCallArchitectures=native
EOF

  cat >/etc/systemd/system/flannel-fdb-fix.timer <<'EOF'
[Unit]
Description=Periodically re-apply missing flannel VXLAN FDB entries

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now flannel-fdb-fix.timer
}

# -- journald ------------------------------------------------------------------
# Cap the journal: logs share the boot volume with images and Longhorn replicas.

cap_journal() {
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=100M\nSystemMaxFileSize=100M\n' \
    > /etc/systemd/journald.conf.d/10-k3s-oci.conf
  systemctl restart systemd-journald
}

# -- Helm ----------------------------------------------------------------------

# For Argo CD's one-time install on the first node: a pinned release tarball,
# checked against its published SHA-256, in /var/lib/k3s-oci/bin (writable on
# every supported OS). Helm 3: Helm 4 renames flags the bootstrap uses
# (--atomic); renovate.json holds it below 4.
# renovate: datasource=github-releases depName=helm/helm
HELM_VERSION="v3.22.1"

HELM=/var/lib/k3s-oci/bin/helm

install_helm() {
  [[ -x "${HELM}" ]] && return 0
  local arch tarball tmp
  case "$(uname -m)" in
    aarch64 | arm64) arch=arm64 ;;
    x86_64) arch=amd64 ;;
    *) echo "ERROR: Helm install: unsupported architecture $(uname -m)."; return 1 ;;
  esac
  tarball="helm-${HELM_VERSION}-linux-${arch}.tar.gz"
  tmp=$(mktemp -d)
  if curl -fsSL -o "${tmp}/${tarball}" "https://get.helm.sh/${tarball}" \
    && curl -fsSL -o "${tmp}/${tarball}.sha256sum" "https://get.helm.sh/${tarball}.sha256sum" \
    && (cd "${tmp}" && sha256sum -c "${tarball}.sha256sum") \
    && tar -xzf "${tmp}/${tarball}" -C "${tmp}" \
    && install -D -m 0755 "${tmp}/linux-${arch}/helm" "${HELM}"; then
    rm -rf "${tmp}"
  else
    rm -rf "${tmp}"
    echo "ERROR: Helm install failed."
    return 1
  fi
}
