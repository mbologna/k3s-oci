# Weekly boot-volume backups, kept one week: one per node, within the five
# volume backups of the Always Free tier. A last resort for the Longhorn data
# and of whatever else lives on the nodes; the database has Oracle's backups.

resource "oci_core_volume_backup_policy" "weekly" {
  count = var.enable_boot_volume_backups ? 1 : 0

  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-weekly"
  freeform_tags  = local.common_tags

  schedules {
    backup_type       = "FULL"
    period            = "ONE_WEEK"
    day_of_week       = "SUNDAY"
    hour_of_day       = 1
    offset_type       = "STRUCTURED"
    retention_seconds = 604800
    time_zone         = "UTC"
  }
}

resource "oci_core_volume_backup_policy_assignment" "node" {
  for_each = var.enable_boot_volume_backups ? var.nodes : {}

  asset_id  = oci_core_instance.node[each.key].boot_volume_id
  policy_id = oci_core_volume_backup_policy.weekly[0].id
}
