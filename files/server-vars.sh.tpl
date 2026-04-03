#!/usr/bin/env bash
# server-vars.sh.tpl — Terraform-rendered header for k3s server cloud-init.
# This is the ONLY file in files/ with Terraform interpolation — all other
# files/lib/*.sh are pure bash with no escaping needed.
# Concatenated by data.tf: join("\n", [templatefile(this), file(lib/common.sh), ...])

set -euo pipefail
exec > >(tee /var/log/k3s-cloud-init.log | logger -t k3s-cloud-init) 2>&1

echo "==> k3s server cloud-init starting at $(date -u)"

# ── Cluster identity ──────────────────────────────────────────────────────────
export K3S_VERSION="${k3s_version}"
export K3S_SUBNET="${k3s_subnet}"
export K3S_URL="${k3s_url}"
export K3S_TLS_SAN="${k3s_tls_san}"
export K3S_TLS_SAN_PUBLIC="${k3s_tls_san_public}"
export COMPARTMENT_OCID="${compartment_ocid}"
export AVAILABILITY_DOMAIN="${availability_domain}"
export CLUSTER_NAME="${cluster_name}"
export GITOPS_REPO_URL="${gitops_repo_url}"

# ── Feature flags ─────────────────────────────────────────────────────────────
export EXPOSE_KUBEAPI="${expose_kubeapi ? "true" : "false"}"
export ENABLE_EXTERNAL_DNS="${enable_external_dns ? "true" : "false"}"
export ENABLE_EXTERNAL_SECRETS="${enable_external_secrets ? "true" : "false"}"
export ENABLE_DNS01_CHALLENGE="${enable_dns01_challenge ? "true" : "false"}"

# ── Secrets (plain-text fallback; empty string when OCI Vault is used) ────────
export K3S_TOKEN_PLAIN="${k3s_token}"
export LONGHORN_UI_PASSWORD_PLAIN="${longhorn_ui_password}"
export GRAFANA_ADMIN_PASSWORD_PLAIN="${grafana_admin_password}"

# ── OCI Vault secret IDs (empty string when enable_vault = false) ─────────────
export VAULT_SECRET_ID_K3S_TOKEN="${vault_secret_id_k3s_token}"
export VAULT_SECRET_ID_LONGHORN_PASSWORD="${vault_secret_id_longhorn_password}"
export VAULT_SECRET_ID_GRAFANA_PASSWORD="${vault_secret_id_grafana_password}"

# ── Chart versions (bootstrap only; ArgoCD adopts and manages ongoing) ────────
export GATEWAY_API_VERSION="${gateway_api_version}"
export CERTMANAGER_CHART_VERSION="${certmanager_chart_version}"
export CERTMANAGER_EMAIL="${certmanager_email_address}"
export ARGOCD_CHART_VERSION="${argocd_chart_version}"
export EXTERNAL_SECRETS_CHART_VERSION="${external_secrets_chart_version}"

# ── Optional integrations ─────────────────────────────────────────────────────
export LONGHORN_UI_USERNAME="${longhorn_ui_username}"
export NOTIFICATION_TOPIC_ENDPOINT="${notification_topic_endpoint}"
export MYSQL_ENDPOINT="${mysql_endpoint}"
export MYSQL_ADMIN_USERNAME="${mysql_admin_username}"
export MYSQL_ADMIN_PASSWORD="${mysql_admin_password}"
export CLOUDFLARE_API_TOKEN="${cloudflare_api_token}"
export CLOUDFLARE_ZONE_ID="${cloudflare_zone_id}"
export EXTERNAL_DNS_DOMAIN_FILTER="${external_dns_domain_filter}"
export VAULT_OCID="${vault_ocid}"
export OCI_REGION="${oci_region}"
