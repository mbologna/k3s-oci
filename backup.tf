# ── Boot volume backup policy ─────────────────────────────────────────────────
# Weekly full backups with 1-week retention = at most 1 active backup per volume.
# With 4 nodes (3 servers + 1 worker) that is 4 concurrent backups — within the
# 5 Always Free volume backup limit.

resource "oci_core_volume_backup_policy" "k3s" {
  count          = var.enable_backup ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-weekly-backup"
  freeform_tags  = local.common_tags

  schedules {
    backup_type       = "FULL"
    period            = "ONE_WEEK"
    retention_seconds = 604800 # 7 days
    day_of_week       = "SUNDAY"
    hour_of_day       = 2
    time_zone         = "UTC"
    offset_type       = "STRUCTURED"
  }
}

# Server pool boot volumes (referenced via data.oci_core_instance.k3s_servers)
resource "oci_core_volume_backup_policy_assignment" "k3s_servers" {
  count     = var.enable_backup ? var.k3s_server_pool_size : 0
  asset_id  = data.oci_core_instance.k3s_servers[count.index].boot_volume_id
  policy_id = oci_core_volume_backup_policy.k3s[0].id
}

# Standalone worker boot volume
resource "oci_core_volume_backup_policy_assignment" "k3s_standalone_worker" {
  count     = var.enable_backup && var.k3s_standalone_worker ? 1 : 0
  asset_id  = oci_core_instance.k3s_standalone_worker[0].boot_volume_id
  policy_id = oci_core_volume_backup_policy.k3s[0].id
}
