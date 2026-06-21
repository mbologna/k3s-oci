#!/usr/bin/env bash
# lib/k3s-agent.sh -- k3s worker node install. Pure bash -- no Terraform interpolation.
# Variables are exported by agent-vars.sh.tpl (prepended by data.tf).
# shellcheck disable=SC2154

# -- k3s agent install ---------------------------------------------------------

install_k3s_agent() {
  local install_params=()

  resolve_flannel_params
  if [[ -n "${LOCAL_IP:-}" ]]; then
    install_params+=("--node-ip" "${LOCAL_IP}" "--flannel-iface" "${FLANNEL_IFACE}")
  fi

  local max_api_attempts=180 max_attempts=10 attempt=0
  local api_port="${KUBE_API_PORT:-6443}"

  echo "Waiting for k3s API at ${K3S_URL}:${api_port} (max ${max_api_attempts} attempts x 10s) ..."
  until curl --output /dev/null --silent --insecure "https://${K3S_URL}:${api_port}"; do
    attempt=$(( attempt + 1 ))
    [[ ${attempt} -ge ${max_api_attempts} ]] && { echo "ERROR: k3s API unreachable after ${max_api_attempts} attempts."; exit 1; }
    # Every 30 attempts (~5 min) log the actual curl error to help diagnose connectivity issues
    if (( attempt % 30 == 0 )); then
      echo "  still waiting (${attempt}/${max_api_attempts}) -- curl error:"
      curl --insecure "https://${K3S_URL}:${api_port}" 2>&1 | head -3 || true
    else
      echo "  attempt ${attempt}/${max_api_attempts} -- sleeping 10s"
    fi
    sleep 10
  done

  attempt=0
  # Install agent WITHOUT starting it. Same issue as k3s-server.sh: the installer
  # writes K3S_URL='' to the env file, which overrides --server in ExecStart.
  # shellcheck disable=SC2097,SC2098  # K3S_URL="" clears env for installer; ${K3S_URL} in arg uses outer scope (intentional)
  until curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="${K3S_VERSION}" K3S_TOKEN="${K3S_TOKEN}" K3S_URL="" \
      INSTALL_K3S_SKIP_START=true \
      sh -s - agent --server "https://${K3S_URL}:${api_port}" "${install_params[@]}"; do
    attempt=$(( attempt + 1 ))
    [[ ${attempt} -ge ${max_attempts} ]] && { echo "ERROR: k3s agent install failed after ${max_attempts} attempts."; exit 1; }
    echo "  retrying (${attempt}/${max_attempts}) ..."
    sleep 15
  done
  # Patch env file before first start: set correct K3S_URL and add K3S_TOKEN.
  if [[ -f /etc/systemd/system/k3s-agent.service.env ]]; then
    sed -i "s|^K3S_URL=.*|K3S_URL='https://${K3S_URL}:${api_port}'|" \
        /etc/systemd/system/k3s-agent.service.env
    if ! grep -q '^K3S_TOKEN=' /etc/systemd/system/k3s-agent.service.env; then
      echo "K3S_TOKEN='${K3S_TOKEN}'" >> /etc/systemd/system/k3s-agent.service.env
    fi
    echo "==> Patched k3s-agent.service.env: K3S_URL + K3S_TOKEN → https://${K3S_URL}:${api_port}"
  fi
  systemctl daemon-reload
  echo "==> Starting k3s-agent..."
  systemctl start k3s-agent
}

# -- Main ----------------------------------------------------------------------

bootstrap
configure_unattended_upgrades
configure_longhorn_prereqs

# Resolve K3S_TOKEN from OCI Vault or plaintext fallback.
# "needs_oci_cli" installs OCI CLI unconditionally on agents (servers install it earlier
# in install_k3s_server). The CLI is always available for Vault fetching and etcd snapshot
# uploads if those features are enabled.
resolve_k3s_token needs_oci_cli

install_k3s_agent

echo "==> k3s agent cloud-init complete at $(date -u)"
