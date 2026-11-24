# ── Object Storage buckets ────────────────────────────────────────────────────
# OCI Always Free Object Storage: 20 GB on Free Tier accounts, 10 GB once the
# tenancy is upgraded to Pay As You Go — shared across all buckets.

data "oci_objectstorage_namespace" "k3s" {
  count          = (var.enable_object_storage_state || var.enable_longhorn_backup) ? 1 : 0
  compartment_id = var.compartment_ocid
}

# Versioned bucket for Terraform/OpenTofu remote state (S3-compatible API).
# Also used for etcd snapshot uploads (via OCI CLI instance_principal, no S3 creds needed).
resource "oci_objectstorage_bucket" "terraform_state" {
  count          = var.enable_object_storage_state ? 1 : 0
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.k3s[0].namespace
  name           = "${var.cluster_name}-terraform-state"
  access_type    = "NoPublicAccess"
  versioning     = "Enabled"
  freeform_tags  = local.common_tags

}

# Versioning keeps every superseded object (incl. etcd snapshot uploads) as a
# noncurrent version even after the pruning script "deletes" it — without this
# policy those versions never actually free space, silently exceeding the Always
# Free Object Storage allowance (found 2026-10-01: 489 noncurrent
# versions / 22.5GB of long-deleted etcd snapshots still billed as live storage).
resource "oci_objectstorage_object_lifecycle_policy" "terraform_state" {
  count     = var.enable_object_storage_state ? 1 : 0
  namespace = data.oci_objectstorage_namespace.k3s[0].namespace
  bucket    = oci_objectstorage_bucket.terraform_state[0].name

  rules {
    name        = "purge-noncurrent-versions"
    action      = "DELETE"
    target      = "previous-object-versions"
    time_amount = 2
    time_unit   = "DAYS"
    is_enabled  = true
  }
}

# Dedicated bucket for Longhorn PVC backups (S3-compatible Longhorn backup target).
resource "oci_objectstorage_bucket" "longhorn_backup" {
  count          = var.enable_longhorn_backup ? 1 : 0
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.k3s[0].namespace
  name           = "${var.cluster_name}-longhorn-backup"
  access_type    = "NoPublicAccess"
  versioning     = "Enabled"
  freeform_tags  = local.common_tags
}

# Same noncurrent-version leak risk as terraform_state above — Longhorn
# overwrites/deletes backup objects as PVC snapshots rotate.
resource "oci_objectstorage_object_lifecycle_policy" "longhorn_backup" {
  count     = var.enable_longhorn_backup ? 1 : 0
  namespace = data.oci_objectstorage_namespace.k3s[0].namespace
  bucket    = oci_objectstorage_bucket.longhorn_backup[0].name

  rules {
    name        = "purge-noncurrent-versions"
    action      = "DELETE"
    target      = "previous-object-versions"
    time_amount = 2
    time_unit   = "DAYS"
    is_enabled  = true
  }
}

# Customer Secret Key for Longhorn S3-compatible backup access.
# Created automatically for the module's service user (create_longhorn_backup_user)
# or for user_ocid; allows cloud-init to wire the Longhorn BackupTarget without
# manual Console steps. The secret key is stored in Terraform state, and in Vault
# (not in user-data) when enable_vault = true.
resource "oci_identity_customer_secret_key" "longhorn_backup" {
  count        = local.longhorn_backup_automated ? 1 : 0
  display_name = "${var.cluster_name}-longhorn-backup"
  user_id      = local.create_longhorn_backup_user ? oci_identity_user.longhorn_backup[0].id : var.user_ocid

  # The capability must be in place before OCI accepts the key.
  depends_on = [oci_identity_user_capabilities_management.longhorn_backup]
}

# ── Fedora CoreOS node scripts ────────────────────────────────────────────────
# Ignition fetches the node script from here (data.tf explains why it cannot be
# inlined). The object keeps its name when the script changes, so a pool replacement
# whose frozen Ignition config still points at the URL boots the current script.
# The script holds what cloud-init user-data holds on other OSes (the shared SSH host
# key; the plaintext secrets when enable_vault = false): the URL is as sensitive as
# user_data, and both live in the instance metadata.
resource "oci_objectstorage_object" "fcos_script" {
  for_each     = var.os_family == "fcos" ? toset(["server", "worker"]) : toset([])
  namespace    = data.oci_objectstorage_namespace.k3s[0].namespace
  bucket       = oci_objectstorage_bucket.terraform_state[0].name
  object       = "k3s-oci/fcos-${each.key}.sh"
  content_type = "text/x-shellscript"
  content      = each.key == "server" ? local.k3s_server_script : local.k3s_worker_script
}

resource "oci_objectstorage_preauthrequest" "fcos_script" {
  for_each     = oci_objectstorage_object.fcos_script
  namespace    = each.value.namespace
  bucket       = each.value.bucket
  name         = "${var.cluster_name}-fcos-${each.key}-script"
  access_type  = "ObjectRead"
  object_name  = each.value.object
  time_expires = "2100-01-01T00:00:00Z"

  lifecycle {
    # Every node that boots, pool replacements included, fetches through this URL: it
    # must outlive the cluster, and a new one would not reach the frozen Ignition
    # configs (compute.tf ignores instance_details). OCI may also return the time in
    # another format.
    ignore_changes = [time_expires]
  }
}
