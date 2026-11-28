# One bucket for the cluster's off-site backups: etcd snapshots (datastore =
# "etcd", prefix etcd/) and Longhorn volume backups (prefix longhorn/), whose
# writers use a bucket-scoped Customer Secret Key managed outside this module;
# with os_family = "fcos" also the node script behind read-only pre-authenticated
# requests (prefix k3s-oci/, nodes.tf).

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_ocid
}

resource "oci_objectstorage_bucket" "backups" {
  compartment_id        = var.compartment_ocid
  namespace             = data.oci_objectstorage_namespace.this.namespace
  name                  = "${var.cluster_name}-backups"
  access_type           = "NoPublicAccess"
  versioning            = "Enabled"
  object_events_enabled = false
  freeform_tags         = local.common_tags
}

# Versioning protects against accidental deletes; noncurrent versions are
# purged after 2 days so pruned backups stop counting against the free
# Object Storage allowance.
resource "oci_objectstorage_object_lifecycle_policy" "backups" {
  namespace = data.oci_objectstorage_namespace.this.namespace
  bucket    = oci_objectstorage_bucket.backups.name

  # IAM changes take a moment to propagate: a first apply can still fail here;
  # apply again.
  depends_on = [oci_identity_policy.object_storage_lifecycle]

  rules {
    name        = "purge-noncurrent-versions"
    action      = "DELETE"
    is_enabled  = true
    target      = "previous-object-versions"
    time_amount = 2
    time_unit   = "DAYS"
  }
}
