#!/usr/bin/env bash
# lib/k3s.sh -- entry point of the node script: write the k3s config and the
# bootstrap manifests Terraform rendered, install and start k3s, and on the first
# node install Argo CD. Pure bash; the OS bootstrap and common.sh come before it.
# shellcheck disable=SC2154

K3S_CONFIG=/etc/rancher/k3s/config.yaml.d/10-k3s-oci.yaml
MANIFESTS=/var/lib/rancher/k3s/server/manifests/k3s-oci-bootstrap.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# The module's settings are a drop-in: /etc/rancher/k3s/config.yaml stays free for
# the consumer, and a drop-in that sorts after 10-k3s-oci.yaml overrides a key.
# k3s's deploy controller applies the manifests on every server and retries until
# their CRDs exist (nodes.tf).
write_k3s_files() {
  install -d -m 0700 "$(dirname "${K3S_CONFIG}")"
  (umask 077 && base64 -d <<<"${K3S_CONFIG_B64}" > "${K3S_CONFIG}")
  if [[ -n "${MANIFESTS_B64}" ]]; then
    install -d -m 0700 "$(dirname "${MANIFESTS}")"
    (umask 077 && base64 -d <<<"${MANIFESTS_B64}" > "${MANIFESTS}")
  fi
}

# The cluster CAs from Terraform (ca.tf), placed before k3s first starts: k3s keeps
# CA files it finds and generates the rest. Never overwritten: a node that has
# run k3s keeps what it has.
seed_ca() {
  local tls=/var/lib/rancher/k3s/server/tls
  [[ -f "${tls}/server-ca.crt" ]] && return 0
  install -d -m 0700 "${tls}"
  local name pem
  while read -r name pem; do
    (umask 077 && base64 -d <<<"${pem}" > "${tls}/${name}")
  done <<<"${CA_FILES}"
  echo "==> Seeded the cluster CAs"
}

install_k3s() {
  if [[ "${OS_FAMILY}" == "flatcar" ]]; then
    # The binary and the unit come from the system extension.
    systemctl enable --now k3s.service
  else
    local version_env=(INSTALL_K3S_CHANNEL="${K3S_CHANNEL}")
    [[ -n "${K3S_VERSION}" ]] && version_env=(INSTALL_K3S_VERSION="${K3S_VERSION}")
    local attempt=0
    until curl -sfL https://get.k3s.io | env "${version_env[@]}" INSTALL_K3S_EXEC=server sh -s -; do
      attempt=$((attempt + 1))
      [[ ${attempt} -ge 10 ]] && { echo "ERROR: the k3s install failed 10 times."; exit 1; }
      echo "  k3s install failed, retrying (${attempt}/10)"
      sleep 15
    done
  fi

  echo "==> Waiting for the Kubernetes API"
  local _
  for _ in $(seq 1 120); do
    k3s kubectl get --raw /readyz >/dev/null 2>&1 && return 0
    sleep 5
  done
  echo "ERROR: the Kubernetes API is not ready after 10 minutes."
  exit 1
}

# Argo CD, once, on the first node: a pinned chart, with the two values
# gitops/apps/argocd.yaml also sets (plain HTTP behind Traefik, Helm inside
# kustomizations), so its first sync changes nothing structural. From then on
# that Application manages Argo CD; the App of Apps comes from the manifests.
bootstrap_argocd() {
  [[ "${FIRST_NODE}" == "true" && -n "${ARGOCD_CHART_VERSION}" ]] || return 0
  install_helm
  k3s kubectl wait --for=condition=Ready "node/${NODE_NAME}" --timeout=600s
  local attempt=0
  until "${HELM}" upgrade --install argocd argo-cd \
      --repo https://argoproj.github.io/argo-helm \
      --version "${ARGOCD_CHART_VERSION}" \
      --namespace argocd --create-namespace \
      --set 'configs.params.server\.insecure=true' \
      --set 'configs.cm.kustomize\.buildOptions=--enable-helm' \
      --atomic --wait --timeout 10m; do
    attempt=$((attempt + 1))
    [[ ${attempt} -ge 5 ]] && { echo "ERROR: the Argo CD install failed 5 times."; exit 1; }
    echo "  Argo CD install failed, retrying (${attempt}/5)"
    sleep 30
  done
  echo "==> Argo CD ${ARGOCD_CHART_VERSION} installed; the App of Apps follows from the bootstrap manifests."
}

# -- Main ------------------------------------------------------------------------

bootstrap
cap_journal
configure_os_updates
configure_longhorn_prereqs
write_k3s_files
seed_ca
setup_k3s_memory_protection
install_k3s
setup_flannel_fdb_fix
bootstrap_argocd

echo "==> k3s-oci node bootstrap of ${NODE_NAME} complete at $(date -u)"
