#!/usr/bin/env bash
# lib/k3s-agent.sh — k3s worker node install. Pure bash — no Terraform interpolation.
# Variables are exported by agent-vars.sh.tpl (prepended by data.tf).
# shellcheck disable=SC2154

# ── k3s agent install ─────────────────────────────────────────────────────────

install_k3s_agent() {
  local install_params=()

  if [[ "${K3S_SUBNET}" != "default_route_table" ]]; then
    local local_ip flannel_iface
    local_ip=$(ip -4 route ls "${K3S_SUBNET}" | grep -Po '(?<=src )(\S+)')
    flannel_iface=$(ip -4 route ls "${K3S_SUBNET}" | grep -Po '(?<=dev )(\S+)')
    install_params+=("--node-ip ${local_ip}" "--flannel-iface ${flannel_iface}")
  fi

  local max_api_wait=60 max_attempts=10 attempt=0

  echo "Waiting for k3s API at ${K3S_URL}:6443 ..."
  until curl --output /dev/null --silent --insecure "https://${K3S_URL}:6443"; do
    attempt=$(( attempt + 1 ))
    [[ ${attempt} -ge ${max_api_wait} ]] && { echo "ERROR: k3s API unreachable after ${max_api_wait} attempts."; exit 1; }
    sleep 10
  done

  attempt=0
  until curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="${K3S_VERSION}" K3S_TOKEN="${K3S_TOKEN}" \
      sh -s - agent --server "https://${K3S_URL}:6443" "${install_params[@]}"; do
    attempt=$(( attempt + 1 ))
    [[ ${attempt} -ge ${max_attempts} ]] && { echo "ERROR: k3s agent install failed after ${max_attempts} attempts."; exit 1; }
    echo "  retrying (${attempt}/${max_attempts}) ..."
    sleep 15
  done
}

# ── Main ──────────────────────────────────────────────────────────────────────

bootstrap
configure_unattended_upgrades
configure_longhorn_prereqs

# Resolve k3s token: OCI Vault when enabled, else from user-data header
if [[ -n "${VAULT_SECRET_ID_K3S_TOKEN}" ]]; then
  export OCI_CLI_AUTH=instance_principal
  export PATH="/root/bin:$PATH"
  install_oci_cli
  echo "Fetching k3s token from OCI Vault..."
  K3S_TOKEN=$(oci secrets secret-bundle get \
    --secret-id "${VAULT_SECRET_ID_K3S_TOKEN}" \
    --query 'data."secret-bundle-content".content' --raw-output | base64 -d)
else
  K3S_TOKEN="${K3S_TOKEN_PLAIN}"
fi
export K3S_TOKEN

install_k3s_agent

echo "==> k3s agent cloud-init complete at $(date -u)"
