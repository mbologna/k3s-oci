#!/usr/bin/env bash
# lib/bootstrap-fcos.sh -- Fedora CoreOS bootstrap for k3s server and agent nodes
# (os_family = "fcos"). Pure bash -- no Terraform interpolation. Ignition (data.tf)
# fetches the assembled script to /var/lib/k3s-oci/bootstrap.sh and runs it from
# k3s-oci-bootstrap.service. Followed by two-phase.sh: packages are layered with
# rpm-ostree and active only after a reboot. /etc, /var, /root and /usr/local (in
# /var) are writable.
#
# OS updates follow OpenShift's model, not Zincati (masked by Ignition): the cluster
# pins the FCOS release (the fcos-os Plan in gitops/fcos-os/, OpenShift's osImageURL),
# system-upgrade-controller rolls it out one drained node at a time (the Machine
# Config Daemon's job), and new nodes pivot to it during their first boot, before
# k3s starts (OpenShift's firstboot pivot). k3s-oci-fcos-update below does the
# pivot: one hop along FCOS's update graph per reboot, barrier releases included.
# set -euo pipefail is set by server-vars.sh.tpl / agent-vars.sh.tpl (always prepended first).
# shellcheck disable=SC2154

# The release new nodes pivot to, written by Ignition from var.fcos_os_version.
FCOS_OS_VERSION_FILE=/etc/k3s-oci/fcos-os-version

install_fcos_update_tool() {
  cat > /usr/local/sbin/k3s-oci-fcos-update <<'TOOLEOF'
#!/bin/bash
# k3s-oci-fcos-update [--stage-only] [RELEASE] -- move this Fedora CoreOS node one hop
# along the update graph toward RELEASE (default: $SYSTEM_UPGRADE_PLAN_LATEST_VERSION,
# set by system-upgrade-controller). Barrier releases are hops of their own, as Zincati
# would take them. A hop is a rebase onto the release's image, pinned by digest.
# Exit 0: booted into RELEASE. Exit 10 (--stage-only): a hop is staged, reboot to
# apply it. Otherwise it reboots after staging, and runs again after the reboot.
set -euo pipefail
stage_only=false
if [ "${1:-}" = "--stage-only" ]; then stage_only=true; shift; fi
target="${1:-${SYSTEM_UPGRADE_PLAN_LATEST_VERSION:-}}"
[ -n "$target" ] || { echo "usage: $0 [--stage-only] RELEASE" >&2; exit 2; }
status=$(rpm-ostree status --json)
booted=$(jq -r '.deployments[] | select(.booted) | .version' <<<"$status")
if [ "$booted" = "$target" ]; then
  echo "k3s-oci-fcos-update: booted into $target."
  exit 0
fi
graph=$(curl -sfL --retry 5 --retry-delay 10 -H 'Accept: application/json' \
  "https://updates.coreos.fedoraproject.org/v1/graph?basearch=$(uname -m)&stream=${FCOS_STREAM:-stable}&rollout_wariness=0&oci=true")
hop=$(jq -r --arg from "$booted" --arg to "$target" '
  .nodes as $n
  | ($n | map(.version)) as $v
  | ($v | index($from)) as $s
  | ($v | index($to)) as $t
  | if $t == null then "ERR: \($to) is not in the update graph"
    elif $s == null then "\($to) \($n[$t].payload)"
    else
      (reduce .edges[] as $e ({}; .[$e[0] | tostring] += [$e[1]])) as $adj
      | {seen: {($s | tostring): true}, q: [[$s, null]], hop: null}
      | until(.hop != null or (.q | length) == 0;
          .q[0] as [$cur, $first]
          | .q |= .[1:]
          | reduce (($adj[$cur | tostring] // [])[]) as $nx (.;
              if .hop != null or .seen[$nx | tostring] then .
              else
                .seen[$nx | tostring] = true
                | ($first // $nx) as $h
                | if $nx == $t then .hop = $h else .q += [[$nx, $h]] end
              end))
      | if .hop == null then "ERR: no update path from \($from) to \($to)"
        else "\($v[.hop]) \($n[.hop].payload)" end
    end
' <<<"$graph")
case "$hop" in ERR:*) echo "k3s-oci-fcos-update: ${hop#ERR: }" >&2; exit 1 ;; esac
read -r hop_version hop_image <<<"$hop"
if [ "$(jq -r '.deployments[] | select(.staged) | .version' <<<"$status")" != "$hop_version" ]; then
  echo "k3s-oci-fcos-update: $booted -> $hop_version (toward $target)."
  rpm-ostree rebase "ostree-image-signed:docker://${hop_image}"
fi
if $stage_only; then exit 10; fi
echo "k3s-oci-fcos-update: rebooting into $hop_version."
systemctl reboot
sleep infinity
TOOLEOF
  chmod 0755 /usr/local/sbin/k3s-oci-fcos-update
}

# Phase 1: the first hop toward the cluster's release, and on top of it what the k3s
# scripts need and the image lacks, in one deployment. FCOS has curl, jq, tar,
# iscsi-initiator-utils and nfs-utils; python3 is for the OCI CLI (a venv) and the
# scripts' inline Python, cronie for the etcd snapshot upload (/etc/cron.d).
# k3s-selinux comes from Rancher's repository for CoreOS, the one the k3s installer
# would add; installed by the installer itself it would land in a deployment of its
# own and make the installer skip starting k3s until a reboot.
fcos_install() {
  cat > /etc/yum.repos.d/rancher-k3s-common.repo <<'EOF'
[rancher-k3s-common-stable]
name=Rancher K3s Common (stable)
baseurl=https://rpm.rancher.io/k3s/stable/common/coreos/noarch
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://rpm.rancher.io/public.key
EOF
  install_fcos_update_tool
  local rc=0
  /usr/local/sbin/k3s-oci-fcos-update --stage-only "$(cat "${FCOS_OS_VERSION_FILE}")" || rc=$?
  [[ ${rc} -eq 0 || ${rc} -eq 10 ]] || return "${rc}"
  rpm-ostree install --idempotent --allow-inactive k3s-selinux python3 cronie
}

# The hops phase 1 could not take (one per boot): reboot until the node runs the
# cluster's release, then carry on. The bootstrap unit runs the script again each boot.
fcos_converge_os() {
  local rc=0
  /usr/local/sbin/k3s-oci-fcos-update --stage-only "$(cat "${FCOS_OS_VERSION_FILE}")" || rc=$?
  case ${rc} in
    0) ;;
    10)
      echo "==> Rebooting into the next Fedora CoreOS release on the way to $(cat "${FCOS_OS_VERSION_FILE}")."
      cp /var/log/k3s-cloud-init.log "/var/log/k3s-cloud-init.pivot-$(date +%s).log" 2>/dev/null || true
      systemctl --no-block reboot
      exit 0
      ;;
    *) echo "ERROR: k3s-oci-fcos-update failed (${rc})."; exit "${rc}" ;;
  esac
}

bootstrap() {
  two_phase_begin fcos_install
  fcos_converge_os

  # k3s-selinux is in the deployment from phase 1 (two-phase.sh).
  two_phase_k3s_selinux

  # The fcos-os Plan (gitops/fcos-os/) selects its nodes by this label. A drop-in
  # after the module's 10-k3s-oci.yaml; `+` appends to its node labels.
  mkdir -p /etc/rancher/k3s/config.yaml.d
  printf 'node-label+:\n  - "k3s-oci.io/os=fcos"\n' > /etc/rancher/k3s/config.yaml.d/20-k3s-oci-fcos.yaml

  # etcd snapshot upload schedule (/etc/cron.d, setup_etcd_snapshot_upload).
  systemctl enable --now crond.service

  # Fedora's iscsid needs dac_override to log in to Longhorn's targets; without it a
  # volume loops between attaching and detaching.
  # https://longhorn.io/kb/troubleshooting-volume-attachment-fails-due-to-selinux-denials/
  if ! semodule -l | grep -qx local_longhorn; then
    echo '(allow iscsid_t self (capability (dac_override)))' > /var/lib/k3s-oci/local_longhorn.cil
    semodule -i /var/lib/k3s-oci/local_longhorn.cil
  fi

  # Cap journal size to protect the boot volume.
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/10-k3s-size-limit.conf << 'JEOF'
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=100M
JEOF
  systemctl restart systemd-journald

  # SSH keys for the core user come from OCI's ssh_authorized_keys metadata
  # (Afterburn), so only the shared host key is written here.
  setup_shared_ssh_host_key
}

configure_unattended_upgrades() {
  # OS updates are a cluster operation (the fcos-os Plan, gitops/fcos-os/): nothing
  # on the node updates or reboots it by itself, and kured has no sentinel to act on.
  echo "OS updates: the fcos-os system-upgrade-controller Plan (gitops/fcos-os/)."
}
