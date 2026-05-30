#!/usr/bin/env bash
# lib/k3s-secrets.sh -- pre-create runtime Kubernetes Secrets before ArgoCD syncs.
# Secrets contain values generated or resolved at Terraform apply time (random passwords,
# Vault-fetched secrets, runtime endpoints). Must exist before the ArgoCD apps that
# reference them sync. Pure bash -- no Terraform interpolation.
#
# shellcheck disable=SC2154

pre_create_secrets() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  # Resolve passwords from OCI Vault or from plain-text user-data header
  if [[ -n "${VAULT_SECRET_ID_LONGHORN_PASSWORD}" ]]; then
    echo "Fetching Longhorn UI password from OCI Vault..."
    LONGHORN_UI_PASSWORD=$(oci secrets secret-bundle get \
      --secret-id "${VAULT_SECRET_ID_LONGHORN_PASSWORD}" \
      --query 'data."secret-bundle-content".content' --raw-output | base64 -d)
  else
    LONGHORN_UI_PASSWORD="${LONGHORN_UI_PASSWORD_PLAIN}"
  fi

  if [[ -n "${VAULT_SECRET_ID_GRAFANA_PASSWORD}" ]]; then
    echo "Fetching Grafana admin password from OCI Vault..."
    GRAFANA_ADMIN_PASSWORD=$(oci secrets secret-bundle get \
      --secret-id "${VAULT_SECRET_ID_GRAFANA_PASSWORD}" \
      --query 'data."secret-bundle-content".content' --raw-output | base64 -d)
  else
    GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD_PLAIN}"
  fi

  # Longhorn BasicAuth -- htpasswd hash generated here because openssl apr1 hashing
  # is not possible inside static gitops YAML. Secret is referenced by
  # gitops/longhorn/ingress.yaml (user-configured HTTPRoute + SecurityPolicy).
  local longhorn_hash
  longhorn_hash=$(openssl passwd -apr1 "${LONGHORN_UI_PASSWORD}")
  kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n longhorn-system -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: longhorn-basic-auth-secret
  namespace: longhorn-system
type: Opaque
stringData:
  .htpasswd: "${LONGHORN_UI_USERNAME}:${longhorn_hash}"
EOF
  echo "Longhorn BasicAuth secret created."

  # Grafana admin secret -- referenced by kube-prometheus-stack ArgoCD app
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n monitoring -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin-secret
  namespace: monitoring
type: Opaque
stringData:
  admin-user: admin
  admin-password: "${GRAFANA_ADMIN_PASSWORD}"
EOF
  echo "Grafana admin secret pre-created in monitoring namespace."

  # Alertmanager config -- always created so kube-prometheus-stack can reference
  # it via alertmanagerSpec.configSecret. Null receiver when OCI Notifications is
  # disabled; OCI webhook receiver when enabled.
  if [[ -n "${NOTIFICATION_TOPIC_ENDPOINT}" ]]; then
    kubectl apply -n monitoring -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-oci-config
  namespace: monitoring
type: Opaque
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: 'oci-notifications'
    receivers:
    - name: 'oci-notifications'
      webhook_configs:
      - url: '${NOTIFICATION_TOPIC_ENDPOINT}'
        send_resolved: true
EOF
  else
    kubectl apply -n monitoring -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-oci-config
  namespace: monitoring
type: Opaque
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: 'null'
    receivers:
    - name: 'null'
EOF
  fi
  echo "Alertmanager config secret created."

  # MySQL credentials -- pre-created so apps can mount this secret on first deploy
  if [[ -n "${MYSQL_ENDPOINT}" ]]; then
    kubectl apply -n default -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mysql-credentials
  namespace: default
type: Opaque
stringData:
  host: "${MYSQL_ENDPOINT}"
  username: "${MYSQL_ADMIN_USERNAME}"
  password: "${MYSQL_ADMIN_PASSWORD}"
  jdbc-url: "jdbc:mysql://${MYSQL_ENDPOINT}/${CLUSTER_NAME}?useSSL=true&requireSSL=true"
EOF
    echo "MySQL credentials secret created (host: ${MYSQL_ENDPOINT})."
  fi

  # Cloudflare credentials for external-dns -- pre-created so the ArgoCD
  # external-dns app (gitops/apps/external-dns.yaml) starts reconciling immediately.
  if [[ "${ENABLE_EXTERNAL_DNS}" == "true" ]]; then
    kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n external-dns -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-credentials
  namespace: external-dns
type: Opaque
stringData:
  apiToken: "${CLOUDFLARE_API_TOKEN}"
EOF
    echo "Cloudflare credentials secret created for external-dns."
  fi
}
