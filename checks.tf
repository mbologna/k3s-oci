# Always Free guardrails: plans that would exceed the free allowance warn
# before anything is created.

check "a1_ocpus_within_free_allowance" {
  assert {
    condition     = sum([for n in var.nodes : n.ocpus]) <= var.a1_free_ocpus
    error_message = "The nodes request ${sum([for n in var.nodes : n.ocpus])} A1 OCPUs; the free allowance is ${var.a1_free_ocpus} (a1_free_ocpus)."
  }
}

check "a1_memory_within_free_allowance" {
  assert {
    condition     = sum([for n in var.nodes : n.memory_gbs]) <= var.a1_free_memory_gbs
    error_message = "The nodes request ${sum([for n in var.nodes : n.memory_gbs])} GB of A1 memory; the free allowance is ${var.a1_free_memory_gbs} GB (a1_free_memory_gbs)."
  }
}

check "block_storage_within_free_allowance" {
  assert {
    condition     = sum([for n in var.nodes : n.boot_gb]) <= 200
    error_message = "The boot volumes total ${sum([for n in var.nodes : n.boot_gb])} GB; Always Free block storage is 200 GB."
  }
}

check "volume_backups_within_free_allowance" {
  assert {
    condition     = !var.enable_boot_volume_backups || length(var.nodes) <= 5
    error_message = "Weekly boot-volume backups keep one backup per node; Always Free allows 5 volume backups."
  }
}

check "mysql_free_shape" {
  assert {
    condition     = var.datastore != "mysql" || var.mysql_shape == "MySQL.Free"
    error_message = "mysql_shape ${var.mysql_shape} is not the Always Free MySQL.Free shape: it is billed."
  }
}

check "node_ips_inside_private_subnet" {
  assert {
    condition = alltrue([
      for n in var.nodes : n.ip_host > 3 && n.ip_host < pow(2, 32 - tonumber(split("/", var.private_subnet_cidr)[1])) - 1
    ])
    error_message = "Every ip_host must be a usable host number of private_subnet_cidr (OCI reserves the first three addresses and the last)."
  }
}

check "user_data_fits" {
  assert {
    condition     = alltrue([for name, ud in local.user_data : length(ud) < 32000])
    error_message = "A node's user_data exceeds OCI's 32,000-byte metadata limit."
  }
}

check "etcd_s3_keys_together" {
  assert {
    condition     = (var.etcd_s3_access_key == null) == (var.etcd_s3_secret_key == null)
    error_message = "Set both etcd_s3_access_key and etcd_s3_secret_key, or neither."
  }
}
