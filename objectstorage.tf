# ── Object Storage bucket for Terraform state ────────────────────────────────
# OCI Always Free: 20 GB Object Storage. Versioning prevents accidental state
# deletion. Uses S3-compatible API (no extra provider needed).

data "oci_objectstorage_namespace" "k3s" {
  count          = var.enable_object_storage_state ? 1 : 0
  compartment_id = var.compartment_ocid
}

resource "oci_objectstorage_bucket" "terraform_state" {
  count          = var.enable_object_storage_state ? 1 : 0
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.k3s[0].namespace
  name           = "${var.cluster_name}-terraform-state"
  access_type    = "NoPublicAccess"
  versioning     = "Enabled"
  freeform_tags  = local.common_tags
}
