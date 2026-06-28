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

# Customer Secret Key for Longhorn S3-compatible backup access.
# Created automatically when user_ocid is provided; allows cloud-init to wire
# the Longhorn BackupTarget without manual Console steps.
# The secret key is stored in Terraform state (encrypted when using the S3 backend).
resource "oci_identity_customer_secret_key" "longhorn_backup" {
  count        = var.enable_longhorn_backup && var.user_ocid != null ? 1 : 0
  display_name = "${var.cluster_name}-longhorn-backup"
  user_id      = var.user_ocid
}
