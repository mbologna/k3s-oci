# ── Object Storage buckets ────────────────────────────────────────────────────
# OCI Always Free: 20 GB Object Storage shared across all buckets.

data "oci_objectstorage_namespace" "k3s" {
  count          = (var.enable_object_storage_state || var.enable_longhorn_backup) ? 1 : 0
  compartment_id = var.compartment_ocid
}

# Versioned bucket for Terraform/OpenTofu remote state (S3-compatible API).
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
# After apply, create an OCI Customer Secret Key and follow the longhorn_backup_setup output.
resource "oci_objectstorage_bucket" "longhorn_backup" {
  count          = var.enable_longhorn_backup ? 1 : 0
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.k3s[0].namespace
  name           = "${var.cluster_name}-longhorn-backup"
  access_type    = "NoPublicAccess"
  versioning     = "Enabled"
  freeform_tags  = local.common_tags
}
