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
