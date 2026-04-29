#!/usr/bin/env bash
# lib/k3s-server.sh — k3s control-plane install, first-server election, and main
# entry point for server nodes. Pure bash — no Terraform interpolation.
# Variables are exported by server-vars.sh.tpl (prepended by data.tf).
# shellcheck disable=SC2154

# ── Wait for kubeapi ──────────────────────────────────────────────────────────

wait_for_kubeapi() {
  local max_attempts=180 attempt=0
  echo "Waiting for k3s API at ${K3S_URL}:6443 ..."
  until curl --output /dev/null --silent --insecure "https://${K3S_URL}:6443"; do
    attempt=$(( attempt + 1 ))
    if [[ $attempt -ge $max_attempts ]]; then
      echo "ERROR: kubeapi not reachable after ${max_attempts} attempts."
      exit 1
    fi
    echo "  attempt ${attempt}/${max_attempts} — sleeping 10s"
    sleep 10
  done
  echo "kubeapi is reachable."
}

# ── First-server election ─────────────────────────────────────────────────────
# Identifies the oldest running server in the cluster's instance pool via OCI
# CLI + IMDSv2. The oldest node bootstraps etcd (--cluster-init); all others join.
#
# Uses the instance pool membership API (preferred) to avoid electing stale
# instances from a previous Terraform apply that are still in RUNNING state
# while being replaced. Falls back to compartment-wide instance list if the
# pool lookup fails.

detect_first_server() {
  export OCI_CLI_AUTH=instance_principal
  export PATH="/root/bin:$PATH"

  local instance_display_name first_server pool_id
  instance_display_name=$(curl -sfL \
    -H "Authorization: Bearer Oracle" \
    http://169.254.169.254/opc/v2/instance | jq -r '.displayName')

  # Find the server pool by cluster tags — pool membership only includes current
  # members, so replaced/stale instances from previous applies are excluded.
  pool_id=$(oci compute-management instance-pool list \
    --compartment-id "${COMPARTMENT_OCID}" \
    --lifecycle-state RUNNING 2>/dev/null \
    | jq -re --arg cluster "${CLUSTER_NAME}" \
        '.data
         | map(select(
             .["freeform-tags"]["k3s-cluster-name"] == $cluster and
             .["freeform-tags"]["k3s-instance-type"] == "k3s-server"
           ))
         | first
         | .id' 2>/dev/null || echo "")

  if [[ -n "${pool_id}" ]]; then
    first_server=$(oci compute-management instance-pool list-instances \
      --instance-pool-id "${pool_id}" \
      --compartment-id "${COMPARTMENT_OCID}" \
      --sort-by TIMECREATED \
      --sort-order ASC 2>/dev/null \
      | jq -re \
          '.data
           | map(select(.state == "Running"))
           | first
           | .["display-name"]' 2>/dev/null || echo "")
  fi

  # Fallback: compartment-wide list (handles edge case where pool lookup fails)
  if [[ -z "${first_server}" ]]; then
    echo "Warning: pool lookup failed, falling back to compartment instance list"
    first_server=$(oci compute instance list \
      --compartment-id "${COMPARTMENT_OCID}" \
      --availability-domain "${AVAILABILITY_DOMAIN}" \
      --sort-by TIMECREATED \
      --sort-order ASC 2>/dev/null \
      | jq -re --arg cluster "${CLUSTER_NAME}" \
          '.data
           | map(select(
               .["freeform-tags"]["k3s-cluster-name"] == $cluster and
               .["freeform-tags"]["k3s-instance-type"] == "k3s-server" and
               (.["lifecycle-state"] | IN("TERMINATED","TERMINATING") | not)
             ))
           | first
           | .["display-name"]' \
      2>/dev/null || echo "")
  fi

  echo "Election: FIRST_SERVER='${first_server}'  SELF='${instance_display_name}'"

  IS_FIRST_SERVER="false"
  [[ "${first_server}" == "${instance_display_name}" ]] && IS_FIRST_SERVER="true"
  export IS_FIRST_SERVER

  echo "Instance: ${instance_display_name}  First: ${IS_FIRST_SERVER}"
}

# ── k3s server install ────────────────────────────────────────────────────────

install_k3s_server() {
  local install_params=("--tls-san" "${K3S_TLS_SAN}")

  resolve_flannel_params
  if [[ -n "${LOCAL_IP:-}" ]]; then
    install_params+=("--node-ip" "${LOCAL_IP}" "--advertise-address" "${LOCAL_IP}" "--flannel-iface" "${FLANNEL_IFACE}")
  fi

  # Always disable k3s built-in Traefik; Envoy Gateway is managed via ArgoCD.
  install_params+=("--disable" "traefik")

  if [[ "${EXPOSE_KUBEAPI}" == "true" ]]; then
    install_params+=("--tls-san" "${K3S_TLS_SAN_PUBLIC}")
  fi

  local max_attempts=10 attempt=0

  if [[ "${IS_FIRST_SERVER}" == "true" ]]; then
    echo "==> Bootstrapping new cluster (--cluster-init)"
    until curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="${K3S_VERSION}" K3S_TOKEN="${K3S_TOKEN}" K3S_URL="" \
        sh -s - --cluster-init "${install_params[@]}"; do
      attempt=$(( attempt + 1 ))
      [[ ${attempt} -ge ${max_attempts} ]] && { echo "ERROR: k3s init failed after ${max_attempts} attempts."; exit 1; }
      echo "  retrying (${attempt}/${max_attempts}) ..."
      sleep 15
    done
  else
    echo "==> Joining existing cluster"
    wait_for_kubeapi
    # shellcheck disable=SC2097,SC2098  # K3S_URL="" clears env for installer; ${K3S_URL} in arg uses outer scope (intentional)
    until curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="${K3S_VERSION}" K3S_TOKEN="${K3S_TOKEN}" K3S_URL="" \
        sh -s - --server "https://${K3S_URL}:6443" "${install_params[@]}"; do
      attempt=$(( attempt + 1 ))
      [[ ${attempt} -ge ${max_attempts} ]] && { echo "ERROR: k3s join failed after ${max_attempts} attempts."; exit 1; }
      echo "  retrying (${attempt}/${max_attempts}) ..."
      sleep 15
    done
  fi
}

# ── Wait for cluster ready ────────────────────────────────────────────────────

wait_for_cluster_ready() {
  local max=60 attempt=0
  local timeout_seconds=$(( max * 10 ))
  echo "Waiting for all nodes to be Ready (timeout: ${timeout_seconds}s) ..."
  until [[ $(kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null \
               | grep -v " Ready " | wc -l) -eq 0 ]] && \
        [[ $(kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null \
               | wc -l) -gt 0 ]]; do
    attempt=$(( attempt + 1 ))
    [[ ${attempt} -ge ${max} ]] && {
      echo "ERROR: cluster not ready after ${timeout_seconds}s."
      kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null || true
      exit 1
    }
    echo "  waiting (${attempt}/${max}, $(( attempt * 10 ))/${timeout_seconds}s) ..."
    sleep 10
  done
  echo "All nodes are Ready."
}

# ── Main ──────────────────────────────────────────────────────────────────────

bootstrap
configure_unattended_upgrades
configure_longhorn_prereqs
install_oci_cli

detect_first_server

# Resolve cluster secrets: OCI Vault when enabled, else from user-data header
if [[ -n "${VAULT_SECRET_ID_K3S_TOKEN}" ]]; then
  echo "Fetching k3s token from OCI Vault..."
  K3S_TOKEN=$(oci secrets secret-bundle get \
    --secret-id "${VAULT_SECRET_ID_K3S_TOKEN}" \
    --query 'data."secret-bundle-content".content' --raw-output | base64 -d)
else
  K3S_TOKEN="${K3S_TOKEN_PLAIN}"
fi
export K3S_TOKEN

install_k3s_server

if [[ "${IS_FIRST_SERVER}" == "true" ]]; then
  wait_for_cluster_ready

  # Remove the control-plane and etcd NoSchedule taints that k3s ≥ 1.24 adds
  # automatically to server nodes. With only one worker, keeping these taints
  # makes the worker a single-node SPOF for user workloads. All four A1.Flex
  # nodes are identically sized, so co-locating etcd and user workloads is safe.
  kubectl taint nodes -l node-role.kubernetes.io/control-plane \
    node-role.kubernetes.io/control-plane:NoSchedule- \
    node-role.kubernetes.io/etcd:NoSchedule- \
    2>/dev/null || true
  echo "Control-plane NoSchedule taints removed — all 4 nodes schedulable."

  # Source bootstrap functions (defined in k3s-bootstrap.sh, prepended by data.tf)
  export PATH="/root/bin:${PATH}"
  export OCI_CLI_AUTH=instance_principal
  run_bootstrap
fi

echo "==> k3s server cloud-init complete at $(date -u)"
