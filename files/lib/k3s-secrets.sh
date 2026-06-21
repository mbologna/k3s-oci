#!/usr/bin/env bash
# lib/k3s-secrets.sh -- pre-create runtime Kubernetes Secrets before ArgoCD syncs.
# Secrets contain values generated or resolved at Terraform apply time (random passwords,
# Vault-fetched secrets, runtime endpoints). Must exist before the ArgoCD apps that
# reference them sync. Pure bash -- no Terraform interpolation.
#
# shellcheck disable=SC2154

pre_create_secrets() {
  # Resolve passwords from OCI Vault or from plain-text user-data header.
  # fetch_from_vault() retries 20×30s to handle IAM propagation delays on new instances.
  if [[ -n "${VAULT_SECRET_ID_LONGHORN_PASSWORD}" ]]; then
    echo "Fetching Longhorn UI password from OCI Vault..."
    if ! LONGHORN_UI_PASSWORD=$(fetch_from_vault "${VAULT_SECRET_ID_LONGHORN_PASSWORD}"); then
      echo "ERROR: Failed to fetch Longhorn UI password from OCI Vault." >&2; exit 1
    fi
  else
    LONGHORN_UI_PASSWORD="${LONGHORN_UI_PASSWORD_PLAIN}"
  fi

  if [[ -n "${VAULT_SECRET_ID_GRAFANA_PASSWORD}" ]]; then
    echo "Fetching Grafana admin password from OCI Vault..."
    if ! GRAFANA_ADMIN_PASSWORD=$(fetch_from_vault "${VAULT_SECRET_ID_GRAFANA_PASSWORD}"); then
      echo "ERROR: Failed to fetch Grafana admin password from OCI Vault." >&2; exit 1
    fi
    [[ -z "${GRAFANA_ADMIN_PASSWORD}" ]] && { echo "ERROR: GRAFANA_ADMIN_PASSWORD is empty after Vault fetch." >&2; exit 1; }
  else
    GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD_PLAIN}"
  fi

  # Resolve Cloudflare token from Vault when available; otherwise use the plain-text
  # value embedded in user-data (CLOUDFLARE_API_TOKEN is empty when vault is enabled).
  if [[ -n "${VAULT_SECRET_ID_CLOUDFLARE:-}" ]]; then
    echo "Fetching Cloudflare API token from OCI Vault..."
    if ! CLOUDFLARE_API_TOKEN=$(fetch_from_vault "${VAULT_SECRET_ID_CLOUDFLARE}"); then
      echo "ERROR: Failed to fetch Cloudflare API token from OCI Vault." >&2; exit 1
    fi
    [[ -z "${CLOUDFLARE_API_TOKEN}" ]] && { echo "ERROR: CLOUDFLARE_API_TOKEN is empty after Vault fetch." >&2; exit 1; }
    export CLOUDFLARE_API_TOKEN
  fi
  # When vault is not used, CLOUDFLARE_API_TOKEN is already exported from server-vars.sh.tpl

  # Longhorn BasicAuth -- htpasswd hash generated here because openssl apr1 hashing
  # is not possible inside static gitops YAML. Secret is referenced by
  # gitops/longhorn/ingress.yaml (user-configured HTTPRoute + SecurityPolicy).
  [[ -z "${LONGHORN_UI_USERNAME}" ]] && { echo "ERROR: LONGHORN_UI_USERNAME is empty — cannot create Longhorn auth secret."; exit 1; }
  [[ -z "${LONGHORN_UI_PASSWORD}" ]] && { echo "ERROR: LONGHORN_UI_PASSWORD is empty — cannot create Longhorn auth secret."; exit 1; }
  local longhorn_hash
  longhorn_hash=$(openssl passwd -apr1 "${LONGHORN_UI_PASSWORD}") || { echo "ERROR: openssl passwd failed."; exit 1; }
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

  # Longhorn backup credentials -- pre-created when Terraform has provisioned a
  # Customer Secret Key (LONGHORN_BACKUP_ACCESS_KEY is non-empty).
  # The Longhorn BackupTarget is applied later in setup_longhorn_backup_target()
  # after Longhorn CRDs are available.
  if [[ "${ENABLE_LONGHORN_BACKUP:-false}" == "true" ]] && [[ -n "${LONGHORN_BACKUP_ACCESS_KEY:-}" ]]; then
    kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n longhorn-system -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: longhorn-backup-secret
  namespace: longhorn-system
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "${LONGHORN_BACKUP_ACCESS_KEY}"
  AWS_SECRET_ACCESS_KEY: "${LONGHORN_BACKUP_SECRET_KEY}"
EOF
    echo "Longhorn backup credentials secret pre-created (longhorn-backup-secret)."
  fi
}

# setup_longhorn_backup_target
# Applies the Longhorn BackupTarget, credential secret reference, and S3 endpoint settings.
# Must be called AFTER Longhorn CRDs are available (i.e. after ArgoCD syncs longhorn app).
# Called from run_bootstrap() alongside ingress configuration (both wait for ArgoCD convergence).

setup_longhorn_backup_target() {
  if [[ "${ENABLE_LONGHORN_BACKUP:-false}" != "true" ]] \
     || [[ -z "${LONGHORN_BACKUP_BUCKET:-}" ]] \
     || [[ -z "${LONGHORN_BACKUP_ACCESS_KEY:-}" ]]; then
    echo "INFO: Longhorn backup target automation skipped (ENABLE_LONGHORN_BACKUP=${ENABLE_LONGHORN_BACKUP:-false} or missing credentials)."
    return 0
  fi

  # Wait for Longhorn CRDs to be available (Longhorn is deployed by ArgoCD)
  local max_wait=60 attempt=0
  echo "Waiting for Longhorn CRDs (longhorn-system) ..."
  until kubectl get crd settings.longhorn.io &>/dev/null 2>&1; do
    attempt=$(( attempt + 1 ))
    if [[ ${attempt} -ge ${max_wait} ]]; then
      echo "WARNING: Longhorn CRDs not ready after ${max_wait} attempts — backup target setup deferred."
      echo "  Run: kubectl apply -f gitops/longhorn/backup-target.yaml (after filling in values)"
      return 0
    fi
    sleep 15
  done

  echo "Applying Longhorn BackupTarget settings..."
  kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Setting
metadata:
  name: backup-target
  namespace: longhorn-system
value: "s3://${LONGHORN_BACKUP_BUCKET}@${OCI_REGION:-${OCI_OBJECT_NAMESPACE}}/"
---
apiVersion: longhorn.io/v1beta2
kind: Setting
metadata:
  name: backup-target-credential-secret
  namespace: longhorn-system
value: "longhorn-backup-secret"
---
apiVersion: longhorn.io/v1beta2
kind: Setting
metadata:
  name: s3-compatible-endpoint
  namespace: longhorn-system
value: "${LONGHORN_BACKUP_ENDPOINT}"
EOF
  echo "Longhorn BackupTarget configured: s3://${LONGHORN_BACKUP_BUCKET} via ${LONGHORN_BACKUP_ENDPOINT}"
}
