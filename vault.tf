# ── OCI Vault (software-protected keys — Always Free) ─────────────────────────
# Always Free: all software-protected master encryption key versions + 150 secrets.
# Stores every cluster secret (2 always + up to 7 optional, see the README's
# "OCI Vault secrets" table) as Vault secrets fetched by cloud-init via OCI CLI
# instance_principal auth at boot. This removes plaintext secrets from user-data.

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

# ── Cluster secrets (for_each over a shared map) ──────────────────────────────
# Collapses the two always-present secrets (k3s_token, longhorn_ui_password) into
# one resource. The conditional secrets below stay separate because each has its
# own enable condition.

locals {
  cluster_vault_secrets = var.enable_vault ? {
    k3s_token = {
      name        = "${var.cluster_name}-k3s-token"
      description = "k3s cluster join token"
      content     = base64encode(random_password.k3s_token.result)
    }
    longhorn_ui_password = {
      name        = "${var.cluster_name}-longhorn-ui-password"
      description = "Longhorn UI BasicAuth password"
      content     = base64encode(random_password.longhorn_ui_password.result)
    }
  } : {}
}

resource "oci_vault_secret" "cluster" {
  for_each = local.cluster_vault_secrets

  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.k3s[0].id
  key_id         = oci_kms_key.k3s[0].id
  secret_name    = each.value.name
  description    = each.value.description

  secret_content {
    content_type = "BASE64"
    content      = each.value.content
  }

  freeform_tags = local.common_tags

  lifecycle {
    ignore_changes = [key_id]
  }
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

  lifecycle {
    ignore_changes = [key_id]
  }
}

resource "oci_vault_secret" "tailscale_oauth_client_secret" {
  count          = var.enable_vault && var.enable_tailscale ? 1 : 0
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.k3s[0].id
  key_id         = oci_kms_key.k3s[0].id
  secret_name    = "${var.cluster_name}-tailscale-client-secret"
  description    = "Tailscale operator OAuth client secret"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.tailscale_oauth_client_secret)
  }

  freeform_tags = local.common_tags

  lifecycle {
    ignore_changes = [key_id]
  }
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

  lifecycle {
    ignore_changes = [key_id]
  }
}

resource "oci_vault_secret" "gitops_https_token" {
  count          = var.enable_vault && var.gitops_https_token != "" ? 1 : 0
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.k3s[0].id
  key_id         = oci_kms_key.k3s[0].id
  secret_name    = "${var.cluster_name}-gitops-https-token"
  description    = "ArgoCD HTTPS access token for the gitops repo (${var.gitops_repo_url})"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.gitops_https_token)
  }

  freeform_tags = local.common_tags

  lifecycle {
    ignore_changes = [key_id]
  }
}

# Store the DockerHub password in Vault when vault is enabled and the credential is set.
# This removes the password from cloud-init user-data (IMDS-accessible) and fetches it
# at bootstrap time via OCI CLI instance_principal instead.
resource "oci_vault_secret" "dockerhub_password" {
  count          = var.enable_vault && var.dockerhub_password != "" ? 1 : 0
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.k3s[0].id
  key_id         = oci_kms_key.k3s[0].id
  secret_name    = "${var.cluster_name}-dockerhub-password"
  description    = "DockerHub registry password for ArgoCD OCI Helm repo credentials"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.dockerhub_password)
  }

  freeform_tags = local.common_tags

  lifecycle {
    ignore_changes = [key_id]
  }
}

# Store the Cloudflare API token in Vault when vault is enabled and the token is set.
# This removes the token from cloud-init user-data (IMDS-accessible) and fetches it
# at bootstrap time via OCI CLI instance_principal instead.
resource "oci_vault_secret" "cloudflare_api_token" {
  count          = var.enable_vault && var.cloudflare_api_token != null ? 1 : 0
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.k3s[0].id
  key_id         = oci_kms_key.k3s[0].id
  secret_name    = "${var.cluster_name}-cloudflare-api-token"
  description    = "Cloudflare API token for external-dns and/or cert-manager DNS-01 challenges"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.cloudflare_api_token)
  }

  freeform_tags = local.common_tags
}

# Longhorn backup S3 secret key: fetched by cloud-init at boot instead of being
# embedded in instance user-data. The access key ID is not a secret and stays in
# user-data. A secret of the same name created by hand must be adopted with
# `tofu import` first (or apply fails with "name already exists").
resource "oci_vault_secret" "longhorn_backup_secret_key" {
  count          = var.enable_vault && local.longhorn_backup_automated ? 1 : 0
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.k3s[0].id
  key_id         = oci_kms_key.k3s[0].id
  secret_name    = "${var.cluster_name}-longhorn-backup-secret-key"
  description    = "S3 secret key of the Longhorn backup Customer Secret Key"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(oci_identity_customer_secret_key.longhorn_backup[0].key)
  }

  freeform_tags = local.common_tags

  lifecycle {
    ignore_changes = [key_id]
  }
}
