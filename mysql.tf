# MySQL HeatWave, the Always Free MySQL.Free shape (one per tenancy, 50 GB):
# the cluster state (datastore = "mysql"), which kine serves to every k3s
# server. etcd's write and fsync load leaves the boot volumes, the servers are
# interchangeable, and Oracle backs the database up every day.

# Only - and _ as special characters: the password goes into kine's DSN, where
# @, / and : would need escaping.
resource "random_password" "mysql_admin" {
  count = var.datastore == "mysql" ? 1 : 0

  length           = 32
  special          = true
  override_special = "-_"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "oci_mysql_mysql_db_system" "k3s" {
  count = var.datastore == "mysql" ? 1 : 0

  compartment_id          = var.compartment_ocid
  availability_domain     = var.availability_domain
  display_name            = "${var.cluster_name}-mysql"
  shape_name              = var.mysql_shape
  subnet_id               = oci_core_subnet.private.id
  nsg_ids                 = [oci_core_network_security_group.mysql[0].id]
  admin_username          = "k3s"
  admin_password          = random_password.mysql_admin[0].result
  data_storage_size_in_gb = 50
  is_highly_available     = false
  freeform_tags           = local.common_tags

  # The free tier keeps one day of automatic backups.
  backup_policy {
    is_enabled        = true
    retention_in_days = 1
  }

  # tofu destroy must work for a rebuild; restore from a backup is a manual
  # choice in the console.
  deletion_policy {
    automatic_backup_retention = "DELETE"
    final_backup               = "SKIP_FINAL_BACKUP"
    is_delete_protected        = false
  }

  lifecycle {
    ignore_changes = [admin_password]
  }
}
