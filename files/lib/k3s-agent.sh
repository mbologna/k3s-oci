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
  # shellcheck disable=SC2097,SC2098  # K3S_URL="" clears env for installer; ${K3S_URL} in arg uses outer scope (intentional)
  until curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="${K3S_VERSION}" K3S_TOKEN="${K3S_TOKEN}" K3S_URL="" \
      sh -s - agent --server "https://${K3S_URL}:${api_port}" "${install_params[@]}"; do
    attempt=$(( attempt + 1 ))
    [[ ${attempt} -ge ${max_attempts} ]] && { echo "ERROR: k3s agent install failed after ${max_attempts} attempts."; exit 1; }
    echo "  retrying (${attempt}/${max_attempts}) ..."
    sleep 15
  done
  # The k3s installer persists all K3S_* env vars (including the inline K3S_URL="")
  # into /etc/systemd/system/k3s-agent.service.env. On any subsequent service restart,
  # K3S_URL='' in the env file wins over --server in ExecStart, causing the agent to
  # lose its server connection. Patch the env file to restore the correct URL.
  if [[ -f /etc/systemd/system/k3s-agent.service.env ]]; then
    sed -i "s|^K3S_URL=.*|K3S_URL='https://${K3S_URL}:${api_port}'|" \
        /etc/systemd/system/k3s-agent.service.env
    echo "==> Patched K3S_URL in k3s-agent.service.env → https://${K3S_URL}:${api_port}"
    systemctl daemon-reload
  fi
}

# -- Main ----------------------------------------------------------------------

bootstrap
configure_unattended_upgrades
configure_longhorn_prereqs

# Resolve k3s token: OCI Vault when enabled, else from user-data header.
# Falls back to K3S_TOKEN_PLAIN when vault fetch fails (handles IAM propagation
# delays that can exceed the retry window on newly created instances).
if [[ -n "${VAULT_SECRET_ID_K3S_TOKEN}" ]]; then
  export OCI_CLI_AUTH=instance_principal
  export PATH="/root/bin:$PATH"
  install_oci_cli
  echo "Fetching k3s token from OCI Vault..."
  if K3S_TOKEN=$(fetch_from_vault "${VAULT_SECRET_ID_K3S_TOKEN}"); then
    echo "Vault fetch successful."
  else
    echo "WARNING: Vault fetch failed — falling back to plaintext token from user-data." >&2
    K3S_TOKEN="${K3S_TOKEN_PLAIN}"
    [[ -z "${K3S_TOKEN}" ]] && { echo "ERROR: K3S_TOKEN_PLAIN is empty — cannot continue." >&2; exit 1; }
  fi
else
  K3S_TOKEN="${K3S_TOKEN_PLAIN}"
fi
export K3S_TOKEN

install_k3s_agent

echo "==> k3s agent cloud-init complete at $(date -u)"
