# ── OCI Vault (software-protected keys — Always Free) ─────────────────────────
# Always Free: all software-protected master encryption key versions + 150 secrets.
# Stores k3s_token, longhorn_ui_password, and grafana_admin_password as Vault
# secrets fetched by cloud-init via OCI CLI instance_principal auth at boot.
# This removes plaintext secrets from instance user-data (cloud-init).

resource "oci_kms_vault" "k3s" {
  count          = var.enable_vault ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-vault"
  vault_type     = "DEFAULT"
  freeform_tags  = local.common_tags

  # OCI DEFAULT vaults have a low tenancy limit and take 7+ days to fully delete
  # (PENDING_DELETION state counts against quota). prevent_destroy keeps the vault
  # alive across tofu destroy/apply cycles so it is never recreated unnecessarily.
  lifecycle {
    prevent_destroy = true
  }
}

resource "oci_kms_key" "k3s" {
  count               = var.enable_vault ? 1 : 0
  compartment_id      = var.compartment_ocid
  display_name        = "${var.cluster_name}-key"
  management_endpoint = oci_kms_vault.k3s[0].management_endpoint

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  protection_mode = "SOFTWARE"
  freeform_tags   = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "oci_vault_secret" "k3s_token" {
  count          = var.enable_vault ? 1 : 0
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.k3s[0].id
  key_id         = oci_kms_key.k3s[0].id
  secret_name    = "${var.cluster_name}-k3s-token"
  description    = "k3s cluster join token"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(random_password.k3s_token.result)
  }

  freeform_tags = local.common_tags
}

resource "oci_vault_secret" "longhorn_ui_password" {
  count          = var.enable_vault ? 1 : 0
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.k3s[0].id
  key_id         = oci_kms_key.k3s[0].id
  secret_name    = "${var.cluster_name}-longhorn-ui-password"
  description    = "Longhorn UI BasicAuth password"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(random_password.longhorn_ui_password.result)
  }

  freeform_tags = local.common_tags
}

resource "oci_vault_secret" "grafana_admin_password" {
  count          = var.enable_vault ? 1 : 0
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.k3s[0].id
  key_id         = oci_kms_key.k3s[0].id
  secret_name    = "${var.cluster_name}-grafana-admin-password"
  description    = "Grafana admin password"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(random_password.grafana_admin_password.result)
  }

  freeform_tags = local.common_tags
}

resource "oci_vault_secret" "tailscale_oauth_client_id" {
  count          = var.enable_vault && var.enable_tailscale ? 1 : 0
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.k3s[0].id
  key_id         = oci_kms_key.k3s[0].id
  secret_name    = "${var.cluster_name}-tailscale-oauth-client-id"
  description    = "Tailscale operator OAuth client ID"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.tailscale_oauth_client_id)
  }

  freeform_tags = local.common_tags
}

resource "oci_vault_secret" "tailscale_oauth_client_secret" {
  count          = var.enable_vault && var.enable_tailscale ? 1 : 0
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.k3s[0].id
  key_id         = oci_kms_key.k3s[0].id
  secret_name    = "${var.cluster_name}-tailscale-oauth-client-secret"
  description    = "Tailscale operator OAuth client secret"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.tailscale_oauth_client_secret)
  }

  freeform_tags = local.common_tags
}

resource "oci_vault_secret" "gitops_ssh_key" {
  count          = var.enable_vault && var.gitops_ssh_private_key != "" ? 1 : 0
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.k3s[0].id
  key_id         = oci_kms_key.k3s[0].id
  secret_name    = "${var.cluster_name}-gitops-ssh-key"
  description    = "ArgoCD SSH deploy key for the gitops repo (${var.gitops_repo_url})"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.gitops_ssh_private_key)
  }

  freeform_tags = local.common_tags
}
