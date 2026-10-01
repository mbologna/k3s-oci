# ── Object Storage buckets ────────────────────────────────────────────────────
# OCI Always Free: 20 GB Object Storage shared across all buckets.

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
# policy those versions never actually free space, silently exceeding the 20GB
# Always Free Object Storage allowance (found 2026-10-01: 489 noncurrent
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
# Created automatically when user_ocid is provided; allows cloud-init to wire
# the Longhorn BackupTarget without manual Console steps.
# The secret key is stored in Terraform state (encrypted when using the S3 backend).
resource "oci_identity_customer_secret_key" "longhorn_backup" {
  count        = var.enable_longhorn_backup && var.user_ocid != null ? 1 : 0
  display_name = "${var.cluster_name}-longhorn-backup"
  user_id      = var.user_ocid
}
