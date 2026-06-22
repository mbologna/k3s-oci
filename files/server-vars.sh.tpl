#!/usr/bin/env bash
# server-vars.sh.tpl -- Terraform-rendered header for k3s server cloud-init.
# This is the ONLY file in files/ with Terraform interpolation -- all other
# files/lib/*.sh are pure bash with no escaping needed.
# Concatenated by data.tf: join("\n", [templatefile(this), file(lib/common.sh), ...])

set -euo pipefail
exec > >(tee /var/log/k3s-cloud-init.log | logger -t k3s-cloud-init) 2>&1

echo "==> k3s server cloud-init starting at $(date -u)"

# Enable bash trace mode when trace_enabled = true in terraform.tfvars.
# Produces verbose output - do NOT enable in production.
export TRACE="${trace_enabled ? "true" : "false"}"
[[ "$${TRACE}" == "true" ]] && set -x

# -- Cluster identity ----------------------------------------------------------
export K3S_VERSION="${k3s_version}"
export K3S_SUBNET="${k3s_subnet}"
export K3S_URL="${k3s_url}"
export KUBE_API_PORT="${kube_api_port}"
export K3S_TLS_SAN="${k3s_tls_san}"
export K3S_TLS_SAN_PUBLIC="${k3s_tls_san_public}"
export COMPARTMENT_OCID="${compartment_ocid}"
export AVAILABILITY_DOMAIN="${availability_domain}"
export CLUSTER_NAME="${cluster_name}"
export GITOPS_REPO_URL="${gitops_repo_url}"
export GITOPS_PATH="${gitops_path}"

# -- Feature flags -------------------------------------------------------------
export EXPOSE_KUBEAPI="${expose_kubeapi ? "true" : "false"}"
export ENABLE_EXTERNAL_DNS="${enable_external_dns ? "true" : "false"}"
export ENABLE_EXTERNAL_SECRETS="${enable_external_secrets ? "true" : "false"}"
export ENABLE_DNS01_CHALLENGE="${enable_dns01_challenge ? "true" : "false"}"

# -- Secrets (plain-text fallback; empty string when OCI Vault is used) --------
export K3S_TOKEN_PLAIN="${k3s_token}"
export LONGHORN_UI_PASSWORD_PLAIN="${longhorn_ui_password}"
export GRAFANA_ADMIN_PASSWORD_PLAIN="${grafana_admin_password}"

# -- OCI Vault secret IDs (empty string when enable_vault = false) -------------
export VAULT_SECRET_ID_K3S_TOKEN="${vault_secret_id_k3s_token}"
export VAULT_SECRET_ID_LONGHORN_PASSWORD="${vault_secret_id_longhorn_password}"
export VAULT_SECRET_ID_GRAFANA_PASSWORD="${vault_secret_id_grafana_password}"
export VAULT_SECRET_ID_GITOPS_SSH_KEY="${vault_secret_id_gitops_ssh_key}"

# -- Chart versions (bootstrap only; ArgoCD adopts and manages ongoing) --------
export GATEWAY_API_VERSION="${gateway_api_version}"
export CERTMANAGER_CHART_VERSION="${certmanager_chart_version}"
export CERTMANAGER_EMAIL="${certmanager_email_address}"
export ARGOCD_CHART_VERSION="${argocd_chart_version}"
export EXTERNAL_SECRETS_CHART_VERSION="${external_secrets_chart_version}"

# -- Cluster services -----------------------------------------------------------
# Grafana ingress: cloud-init creates the Gateway listener, TLS cert, and HTTPRoute
# so that gitops/ files are IP-independent. Empty = skip Grafana HTTPS setup.
export GRAFANA_HOSTNAME="${grafana_hostname}"
# ArgoCD ingress: same pattern as Grafana. Auto-derived as argocd.<nlb-ip>.sslip.io if null.
export ARGOCD_HOSTNAME="${argocd_hostname}"
# Longhorn ingress: set longhorn_hostname in tfvars to enable. No sslip.io fallback.
export LONGHORN_HOSTNAME="${longhorn_hostname}"

# -- Optional integrations -----------------------------------------------------
export LONGHORN_UI_USERNAME="${longhorn_ui_username}"
export NOTIFICATION_TOPIC_ENDPOINT="${notification_topic_endpoint}"
export MYSQL_ENDPOINT="${mysql_endpoint}"
export MYSQL_ADMIN_USERNAME="${mysql_admin_username}"
export MYSQL_ADMIN_PASSWORD="${mysql_admin_password}"
export CLOUDFLARE_API_TOKEN="${cloudflare_api_token}"
export CLOUDFLARE_ZONE_ID="${cloudflare_zone_id}"
export EXTERNAL_DNS_DOMAIN_FILTER="${external_dns_domain_filter}"
# Vault secret ID for the Cloudflare token (empty when enable_vault=false or token not set)
export VAULT_SECRET_ID_CLOUDFLARE="${vault_secret_id_cloudflare}"
export VAULT_OCID="${vault_ocid}"
export OCI_REGION="${oci_region}"
export DOCKERHUB_USERNAME="${dockerhub_username}"
export DOCKERHUB_PASSWORD="${dockerhub_password}"
# Vault secret ID for the DockerHub password (empty when enable_vault=false or password not set)
export VAULT_SECRET_ID_DOCKERHUB="${vault_secret_id_dockerhub}"

# -- etcd snapshot upload (requires enable_etcd_snapshots + enable_object_storage_state) ----
# Enables a cron job that uploads k3s etcd snapshots to OCI Object Storage every 6h.
# Uses OCI CLI instance_principal auth — no Customer Secret Keys required.
# ETCD_SNAPSHOT_BUCKET is empty when enable_etcd_snapshots = false.
export ENABLE_ETCD_SNAPSHOTS="${enable_etcd_snapshots ? "true" : "false"}"
export ETCD_SNAPSHOT_BUCKET="${etcd_snapshot_bucket}"
export ETCD_SNAPSHOT_RETENTION="${etcd_snapshot_retention}"
export OCI_OBJECT_NAMESPACE="${oci_object_namespace}"
# CLUSTER_LOCK_BUCKET is set whenever enable_object_storage_state=true, independent of
# enable_etcd_snapshots. Used by claim_first_server_lock() to ensure split-brain protection
# is not accidentally disabled by toggling the etcd snapshots feature flag.
export CLUSTER_LOCK_BUCKET="${cluster_lock_bucket}"

# -- Longhorn backup target (requires enable_longhorn_backup + user_ocid set) -----
# When user_ocid is set, Terraform creates a Customer Secret Key and cloud-init
# auto-wires the Longhorn BackupTarget. LONGHORN_BACKUP_* vars are empty when
# enable_longhorn_backup = false or user_ocid is not set (manual wiring required).
export ENABLE_LONGHORN_BACKUP="${enable_longhorn_backup ? "true" : "false"}"
export LONGHORN_BACKUP_BUCKET="${longhorn_backup_bucket}"
export LONGHORN_BACKUP_ENDPOINT="${longhorn_backup_endpoint}"
export LONGHORN_BACKUP_ACCESS_KEY="${longhorn_backup_access_key}"
export LONGHORN_BACKUP_SECRET_KEY="${longhorn_backup_secret_key}"

# -- Shared SSH host key (base64-encoded to survive multi-line export) ----------
export SSH_HOST_KEY_PRIVATE_B64="${ssh_host_key_private_b64}"
export SSH_HOST_KEY_PUBLIC="${ssh_host_key_public}"

# -- OS family and default SSH user --------------------------------------------
export OS_FAMILY="${os_family}"
export OS_USER="${os_user}"
# SSH_PUBLIC_KEY is used by bootstrap-opensuse.sh to inject the key directly,
# because openSUSE cloud-init does not read OCI metadata ssh_authorized_keys.
export SSH_PUBLIC_KEY="${ssh_public_key}"
