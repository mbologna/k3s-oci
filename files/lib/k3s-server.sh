#!/usr/bin/env bash
# lib/k3s-server.sh -- k3s control-plane install, first-server election, and main
# entry point for server nodes. Pure bash -- no Terraform interpolation.
# Variables are exported by server-vars.sh.tpl (prepended by data.tf).
# shellcheck disable=SC2154

# -- Wait for kubeapi ----------------------------------------------------------

wait_for_kubeapi() {
  local max_attempts=180 attempt=0
  echo "Waiting for k3s API at ${K3S_URL}:${KUBE_API_PORT:-6443} ..."
  until curl --output /dev/null --silent --insecure "https://${K3S_URL}:${KUBE_API_PORT:-6443}"; do
    attempt=$(( attempt + 1 ))
    if [[ $attempt -ge $max_attempts ]]; then
      echo "ERROR: kubeapi not reachable after ${max_attempts} attempts."
      exit 1
    fi
    echo "  attempt ${attempt}/${max_attempts} -- sleeping 10s"
    sleep 10
  done
  echo "kubeapi is reachable."
}

# -- First-server election -----------------------------------------------------
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

  local instance_display_name="" first_server="" pool_id=""
  instance_display_name=$(curl -sfL --max-time 10 \
    -H "Authorization: Bearer Oracle" \
    http://169.254.169.254/opc/v2/instance | jq -r '.displayName') || {
    echo "ERROR: IMDS fetch failed — cannot determine instance display name for first-server election."
    exit 1
  }

  # Find the server pool by cluster tags -- pool membership only includes current
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
    # Capture both display-name and OCID in a single API call so we can resolve
    # the first server's private IP without a second list-instances call.
    local first_server_json
    first_server_json=$(oci compute-management instance-pool list-instances \
      --instance-pool-id "${pool_id}" \
      --compartment-id "${COMPARTMENT_OCID}" \
      --sort-by TIMECREATED \
      --sort-order ASC 2>/dev/null \
      | jq -re \
          '.data
           | map(select(.state == "Running"))
           | first' 2>/dev/null || echo "null")

    first_server=$(echo "${first_server_json}" | jq -re '.["display-name"]' 2>/dev/null || echo "")

    # Resolve the first server's private IP so joining nodes can connect directly,
    # bypassing the internal LB (which round-robins to UNKNOWN/unready backends).
    local first_server_ocid
    first_server_ocid=$(echo "${first_server_json}" | jq -re '.id' 2>/dev/null || echo "")
    if [[ -n "${first_server_ocid}" ]]; then
      FIRST_SERVER_IP=$(oci compute instance list-vnics \
        --instance-id "${first_server_ocid}" \
        --compartment-id "${COMPARTMENT_OCID}" 2>/dev/null \
        | jq -re '.data[0]["private-ip"]' 2>/dev/null || echo "")
      echo "First server OCID: ${first_server_ocid}  IP: ${FIRST_SERVER_IP}"
    fi
  fi

  # Fallback: compartment-wide list (handles edge case where pool lookup fails)
  if [[ -z "${first_server}" ]]; then
    echo "Warning: pool lookup failed, falling back to compartment instance list"
    local fallback_json
    fallback_json=$(oci compute instance list \
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
           | first' \
      2>/dev/null || echo "null")

    first_server=$(echo "${fallback_json}" | jq -re '.["display-name"]' 2>/dev/null || echo "")

    # Also resolve IP from fallback path
    local fallback_ocid
    fallback_ocid=$(echo "${fallback_json}" | jq -re '.id' 2>/dev/null || echo "")
    if [[ -n "${fallback_ocid}" && -z "${FIRST_SERVER_IP:-}" ]]; then
      FIRST_SERVER_IP=$(oci compute instance list-vnics \
        --instance-id "${fallback_ocid}" \
        --compartment-id "${COMPARTMENT_OCID}" 2>/dev/null \
        | jq -re '.data[0]["private-ip"]' 2>/dev/null || echo "")
      echo "First server (fallback) OCID: ${fallback_ocid}  IP: ${FIRST_SERVER_IP}"
    fi
  fi

  echo "Election: FIRST_SERVER='${first_server}'  SELF='${instance_display_name}'"

  IS_FIRST_SERVER="false"
  [[ "${first_server}" == "${instance_display_name}" ]] && IS_FIRST_SERVER="true"
  export IS_FIRST_SERVER
  export FIRST_SERVER_IP

  echo "Instance: ${instance_display_name}  First: ${IS_FIRST_SERVER}  First IP: ${FIRST_SERVER_IP:-unknown}"
}

# -- Atomic cluster-init leader lock ------------------------------------------
# Uses a conditional PUT (--if-none-match "*") to OCI Object Storage to
# ensure only one node runs --cluster-init, preventing the two-cluster
# split-brain scenario when multiple nodes boot simultaneously.
#
# The lock is skipped (best-effort only) when the state bucket is not
# configured (ETCD_SNAPSHOT_BUCKET empty). In that case the TIMECREATED
# election alone determines the first server.
#
# On a full cluster rebuild, the previous deployment's lock will exist.
# The function detects stale locks by comparing the holder's instance OCID
# lifecycle state — if the holder's instance is gone/terminated, the lock
# is overwritten.

claim_first_server_lock() {
  if [[ -z "${ETCD_SNAPSHOT_BUCKET:-}" ]] || [[ -z "${OCI_OBJECT_NAMESPACE:-}" ]]; then
    echo "INFO: Object Storage not configured; leader lock skipped (TIMECREATED election only)."
    return 0
  fi

  local lock_object="cluster-init-lock"
  local my_ocid
  my_ocid=$(curl -sfL --max-time 10 \
    -H "Authorization: Bearer Oracle" \
    http://169.254.169.254/opc/v2/instance 2>/dev/null \
    | jq -r '.id' 2>/dev/null || hostname)

  local tmp_lock
  tmp_lock=$(mktemp)
  printf '%s:%s:%s' "${CLUSTER_NAME}" "${my_ocid}" "$(date -u +%s)" > "${tmp_lock}"

  echo "Attempting cluster-init leader lock (conditional PUT)..."

  if oci os object put \
      --namespace "${OCI_OBJECT_NAMESPACE}" \
      --bucket-name "${ETCD_SNAPSHOT_BUCKET}" \
      --name "${lock_object}" \
      --file "${tmp_lock}" \
      --if-none-match "*" \
      --no-multipart 2>/dev/null; then
    rm -f "${tmp_lock}"
    echo "Leader lock claimed successfully — proceeding with --cluster-init."
    return 0
  fi

  rm -f "${tmp_lock}"

  # Lock exists — read the holder
  local existing
  existing=$(oci os object get \
    --namespace "${OCI_OBJECT_NAMESPACE}" \
    --bucket-name "${ETCD_SNAPSHOT_BUCKET}" \
    --name "${lock_object}" \
    --file - 2>/dev/null | tr -d '\n' || echo "")

  local existing_cluster existing_ocid
  existing_cluster=$(printf '%s' "${existing}" | cut -d: -f1)
  existing_ocid=$(printf '%s' "${existing}" | cut -d: -f2)

  echo "  Existing lock: '${existing}'"

  # Different cluster name → stale lock from a previous deployment; overwrite.
  if [[ "${existing_cluster}" != "${CLUSTER_NAME}" ]]; then
    echo "  Stale lock from cluster '${existing_cluster}' — overwriting with current cluster."
    local tmp_new
    tmp_new=$(mktemp)
    printf '%s:%s:%s' "${CLUSTER_NAME}" "${my_ocid}" "$(date -u +%s)" > "${tmp_new}"
    oci os object put \
      --namespace "${OCI_OBJECT_NAMESPACE}" \
      --bucket-name "${ETCD_SNAPSHOT_BUCKET}" \
      --name "${lock_object}" \
      --file "${tmp_new}" \
      --force \
      --no-multipart 2>/dev/null || true
    rm -f "${tmp_new}"
    return 0
  fi

  # Same cluster — check if the lock holder's instance is still running
  if [[ -n "${existing_ocid}" && "${existing_ocid}" != "${my_ocid}" ]]; then
    local holder_state
    holder_state=$(oci compute instance get \
      --instance-id "${existing_ocid}" \
      --query 'data."lifecycle-state"' \
      --raw-output 2>/dev/null || echo "UNKNOWN")

    if [[ "${holder_state}" != "RUNNING" ]]; then
      echo "  Lock holder instance is ${holder_state} (not running) — stale lock, overwriting."
      local tmp_reclaim
      tmp_reclaim=$(mktemp)
      printf '%s:%s:%s' "${CLUSTER_NAME}" "${my_ocid}" "$(date -u +%s)" > "${tmp_reclaim}"
      oci os object put \
        --namespace "${OCI_OBJECT_NAMESPACE}" \
        --bucket-name "${ETCD_SNAPSHOT_BUCKET}" \
        --name "${lock_object}" \
        --file "${tmp_reclaim}" \
        --force \
        --no-multipart 2>/dev/null || true
      rm -f "${tmp_reclaim}"
      return 0
    fi
  fi

  # Valid lock held by a running instance
  echo ""
  echo "ERROR: cluster-init leader lock is held by running instance '${existing_ocid}'."
  echo "  Another node is already bootstrapping or has bootstrapped the cluster."
  echo "  This node must NOT run --cluster-init."
  echo ""
  echo "  If this is after a deliberate full cluster wipe/rebuild, delete the lock:"
  echo "    oci os object delete --namespace ${OCI_OBJECT_NAMESPACE} \\"
  echo "      --bucket-name ${ETCD_SNAPSHOT_BUCKET} --name ${lock_object} --force"
  return 1
}



install_k3s_server() {
  local install_params=("--tls-san" "${K3S_TLS_SAN}")

  resolve_flannel_params
  if [[ -n "${LOCAL_IP:-}" ]]; then
    install_params+=("--node-ip" "${LOCAL_IP}" "--advertise-address" "${LOCAL_IP}" "--flannel-iface" "${FLANNEL_IFACE}")
  fi

  # Always disable k3s built-in Traefik; Envoy Gateway is managed via ArgoCD.
  install_params+=("--disable" "traefik")

  # Expose embedded etcd metrics on :2381 so Prometheus can scrape quorum/latency.
  # EtcdNoLeader / EtcdInsufficientMembers alerts depend on this endpoint being reachable.
  install_params+=("--etcd-expose-metrics")

  if [[ "${EXPOSE_KUBEAPI}" == "true" ]]; then
    install_params+=("--tls-san" "${K3S_TLS_SAN_PUBLIC}")
  fi

  local max_attempts=10 attempt=0

  if [[ "${IS_FIRST_SERVER}" == "true" ]]; then
    # Claim the atomic leader lock before running --cluster-init. If another node
    # already holds the lock, this aborts rather than creating a second etcd cluster.
    claim_first_server_lock || exit 1

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

    # Connect directly to the first server's private IP, bypassing the internal LB.
    # OCI Flex LB includes UNKNOWN-state backends in ROUND_ROBIN rotation for up to
    # ~30 s after creation — long enough to route a joining server's bootstrap
    # request to another joining server (which has nothing on :6443), causing k3s
    # to create a standalone etcd cluster (split-brain). The first server's direct
    # IP is always the right target during bootstrap: it's the only node with k3s
    # running.
    #
    # IMPORTANT: if FIRST_SERVER_IP is empty (OCI API failure, IAM propagation delay),
    # we ABORT rather than falling back to K3S_URL (the internal LB). The LB fallback
    # is the exact path that caused the original split-brain. Fail closed; the node
    # will restart via cloud-init retry on next boot.
    if [[ -z "${FIRST_SERVER_IP:-}" ]]; then
      echo "ERROR: FIRST_SERVER_IP is empty — cannot determine first server's direct IP."
      echo "  This means OCI instance pool IP resolution failed (IAM propagation delay or API error)."
      echo "  NOT falling back to the internal LB (K3S_URL) to prevent split-brain."
      echo "  The node will retry on next boot. Check cloud-init logs for OCI CLI errors."
      exit 1
    fi

    local join_url="${FIRST_SERVER_IP}"
    echo "  Joining via: https://${join_url}:${KUBE_API_PORT:-6443}"

    # Wait for the first server's API directly (bypassing the LB).
    local max_wait=180 wait_attempt=0
    echo "Waiting for first server API at ${join_url}:${KUBE_API_PORT:-6443} ..."
    until curl --output /dev/null --silent --insecure \
        "https://${join_url}:${KUBE_API_PORT:-6443}"; do
      wait_attempt=$(( wait_attempt + 1 ))
      [[ ${wait_attempt} -ge ${max_wait} ]] && {
        echo "ERROR: First server API not reachable after ${max_wait} attempts."
        exit 1
      }
      echo "  attempt ${wait_attempt}/${max_wait} -- sleeping 10s"
      sleep 10
    done
    echo "First server API is reachable."

    # Install k3s WITHOUT starting it. The installer writes K3S_URL='' (from the
    # inline env override) into k3s.service.env. If k3s starts with that empty
    # value it ignores --server in ExecStart and bootstraps a standalone sqlite3
    # cluster. INSTALL_K3S_SKIP_START=true prevents this — we patch the env file
    # first, then start k3s so it joins the existing cluster on first boot.
    # shellcheck disable=SC2097,SC2098  # K3S_URL="" clears env for installer; ${join_url} in arg uses outer scope (intentional)
    until curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="${K3S_VERSION}" K3S_TOKEN="${K3S_TOKEN}" K3S_URL="" \
        INSTALL_K3S_SKIP_START=true \
        sh -s - --server "https://${join_url}:${KUBE_API_PORT:-6443}" "${install_params[@]}"; do
      attempt=$(( attempt + 1 ))
      [[ ${attempt} -ge ${max_attempts} ]] && { echo "ERROR: k3s install failed after ${max_attempts} attempts."; exit 1; }
      echo "  retrying (${attempt}/${max_attempts}) ..."
      sleep 15
    done

    # Patch the env file before first start.
    # K3S_URL: use first server's direct IP so the runtime join goes to the right
    # node (same reasoning as above — bypasses LB UNKNOWN-state routing).
    # Server nodes use local etcd on subsequent restarts and don't require K3S_URL
    # to be reachable, so keeping the direct IP permanently is safe.
    # K3S_TOKEN: the installer doesn't persist it for security reasons.
    if [[ -f /etc/systemd/system/k3s.service.env ]]; then
      sed -i "s|^K3S_URL=.*|K3S_URL='https://${join_url}:${KUBE_API_PORT:-6443}'|" \
          /etc/systemd/system/k3s.service.env
      if ! grep -q '^K3S_TOKEN=' /etc/systemd/system/k3s.service.env; then
        echo "K3S_TOKEN='${K3S_TOKEN}'" >> /etc/systemd/system/k3s.service.env
      fi
      echo "==> Patched k3s.service.env: K3S_URL → https://${join_url}:${KUBE_API_PORT:-6443}"
    fi
    systemctl daemon-reload
    echo "==> Starting k3s to join cluster..."
    systemctl start k3s
  fi
}

# -- Wait for cluster ready ----------------------------------------------------

wait_for_cluster_ready() {
  local timeout_seconds=600
  echo "Waiting for all nodes to be Ready (timeout: ${timeout_seconds}s) ..."
  # Export KUBECONFIG so kubectl can find the cluster config
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  # Wait for at least 1 node to exist before calling kubectl wait
  local attempt=0 max=60
  until [[ $(kubectl get nodes --no-headers 2>/dev/null | wc -l) -gt 0 ]]; do
    attempt=$(( attempt + 1 ))
    [[ ${attempt} -ge ${max} ]] && { echo "ERROR: no nodes appeared after ${max} attempts."; exit 1; }
    sleep 5
  done
  kubectl wait --for=condition=Ready nodes --all --timeout="${timeout_seconds}s"
  echo "All nodes are Ready."
}

# -- Main ----------------------------------------------------------------------

bootstrap
configure_unattended_upgrades
configure_longhorn_prereqs
install_oci_cli

detect_first_server

# Resolve K3S_TOKEN from OCI Vault or plaintext fallback.
# OCI CLI is already installed above; OCI_CLI_AUTH is already set by detect_first_server().
resolve_k3s_token

install_k3s_server

if [[ "${IS_FIRST_SERVER}" == "true" ]]; then
  wait_for_cluster_ready

  # Remove the control-plane and etcd NoSchedule taints that k3s >= 1.24 adds
  # automatically to server nodes. With only one worker, keeping these taints
  # makes the worker a single-node SPOF for user workloads. All four A1.Flex
  # nodes are identically sized, so co-locating etcd and user workloads is safe.
  kubectl taint nodes -l node-role.kubernetes.io/control-plane \
    node-role.kubernetes.io/control-plane:NoSchedule- \
    node-role.kubernetes.io/etcd:NoSchedule- \
    2>/dev/null || true
  echo "Control-plane NoSchedule taints removed -- all 4 nodes schedulable."

  # Set up etcd snapshot upload cron job (uploads to OCI Object Storage every 6h).
  # Must be called after k3s is running (needs k3s etcd-snapshot CLI tool).
  setup_etcd_snapshot_upload

  # Source bootstrap functions (defined in k3s-bootstrap.sh, prepended by data.tf)
  export PATH="/root/bin:${PATH}"
  export OCI_CLI_AUTH=instance_principal
  run_bootstrap
fi

echo "==> k3s server cloud-init complete at $(date -u)"
