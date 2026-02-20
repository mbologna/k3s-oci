# ── MySQL HeatWave (Always Free) ──────────────────────────────────────────────
# Always Free: standalone single-node MySQL HeatWave DB system, 50 GB storage.
# Placed in the private subnet — reachable from all k3s nodes (port 3306).
# cloud-init pre-creates a Kubernetes Secret 'mysql-credentials' in the
# 'default' namespace so applications can mount it directly.

resource "random_password" "mysql_admin_password" {
  count            = var.enable_mysql ? 1 : 0
  length           = 24
  special          = true
  override_special = "@#%^&*"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
  keepers          = { cluster_name = var.cluster_name }
}

resource "oci_mysql_mysql_db_system" "k3s" {
  count                   = var.enable_mysql ? 1 : 0
  compartment_id          = var.compartment_ocid
  availability_domain     = var.availability_domain
  display_name            = "${var.cluster_name}-mysql"
  shape_name              = var.mysql_shape
  subnet_id               = oci_core_subnet.private.id
  admin_username          = var.mysql_admin_username
  admin_password          = random_password.mysql_admin_password[0].result
  data_storage_size_in_gb = 50
  is_highly_available     = false
  freeform_tags           = local.common_tags
}
