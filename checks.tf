# Feature flag dependency checks.
# Uses Terraform 1.9+ check{} blocks (required_version >= 1.9.0) to catch
# invalid variable combinations at plan time with clear error messages,
# before any OCI API call is made.

# Warns after Renovate bumps opensuse_leap_version until the new release is imported
# (scripts/import-opensuse-aarch64.sh); a rebuild boots the older image meanwhile.
# A pinned image imported before the script recorded operatingSystemVersion is matched by display name.
check "opensuse_image_matches_leap_version" {
  assert {
    condition = var.os_family != "opensuse" || (
      var.os_image_id == null
      ? length(local.opensuse_images) == 0 || length(local.opensuse_matching_images) > 0
      : try(
        data.oci_core_image.opensuse[0].operating_system_version == var.opensuse_leap_version ||
        can(regex("Leap-${replace(var.opensuse_leap_version, ".", "\\.")}([^0-9]|$)", data.oci_core_image.opensuse[0].display_name)),
        true
      )
    )
    error_message = "The openSUSE image a rebuild would boot is not openSUSE Leap ${var.opensuse_leap_version}. Run scripts/import-opensuse-aarch64.sh --leap-version ${var.opensuse_leap_version}${var.os_image_id != null ? " and set os_image_id to the new OCID (or unset it to auto-resolve)" : ""}. Running nodes are not replaced."
  }
}

# OCI rejects an instance whose metadata (user_data plus ssh_authorized_keys) is over
# 32,000 bytes. Comment stripping in data.tf keeps the scripts under it; this warns
# before a change to the scripts or an extra OS layer pushes them past it.
check "user_data_within_oci_limit" {
  assert {
    condition = alltrue([
      for ud in [data.cloudinit_config.k3s_server.rendered, data.cloudinit_config.k3s_worker.rendered] :
      length(ud) + length(local.ssh_public_key) <= 32000
    ])
    error_message = "Node metadata exceeds OCI's 32,000-byte limit (server user_data ${length(data.cloudinit_config.k3s_server.rendered)} bytes, worker ${length(data.cloudinit_config.k3s_worker.rendered)} bytes, SSH keys ${length(local.ssh_public_key)} bytes): new instances would fail to launch. Shorten the scripts in files/lib/ or the SSH key list."
  }
}

check "external_secrets_requires_vault" {
  assert {
    condition     = !var.enable_external_secrets || var.enable_vault
    error_message = "enable_external_secrets = true requires enable_vault = true (ClusterSecretStore uses OCI Vault via instance_principal)."
  }
}

check "external_secrets_requires_region" {
  assert {
    condition     = !var.enable_external_secrets || var.region != null
    error_message = "enable_external_secrets = true requires region to be set (used in the OCI Vault ClusterSecretStore endpoint)."
  }
}

check "custom_ca_requires_vault" {
  assert {
    condition     = var.k3s_ca_vault_secret_id == null || var.enable_vault
    error_message = "k3s_ca_vault_secret_id requires enable_vault = true (the nodes' read secret-family grant is only added with the Vault)."
  }
}

check "dns01_requires_cloudflare_token" {
  assert {
    condition     = !var.enable_dns01_challenge || var.cloudflare_api_token != null
    error_message = "enable_dns01_challenge = true requires cloudflare_api_token (used by cert-manager for Cloudflare DNS-01 ACME challenges)."
  }
}

check "external_dns_requires_cloudflare" {
  assert {
    condition     = !var.enable_external_dns || (var.cloudflare_api_token != null && var.cloudflare_zone_id != null && var.external_dns_domain_filter != null)
    error_message = "enable_external_dns = true requires cloudflare_api_token, cloudflare_zone_id, and external_dns_domain_filter."
  }
}

check "tailscale_requires_vault" {
  assert {
    condition     = !var.enable_tailscale || var.enable_vault
    error_message = "enable_tailscale = true requires enable_vault = true (OAuth credentials are stored in OCI Vault and synced via ExternalSecret)."
  }
}

check "tailscale_requires_credentials" {
  assert {
    condition     = !var.enable_tailscale || (var.tailscale_oauth_client_id != null && var.tailscale_oauth_client_secret != null)
    error_message = "enable_tailscale = true requires tailscale_oauth_client_id and tailscale_oauth_client_secret."
  }
}

check "backup_count_within_free_limit" {
  assert {
    # backup.tf assigns policies only to server pool instances and the standalone worker,
    # NOT to k3s_worker_pool instances. The pool worker count is excluded here to match.
    condition = !var.enable_backup || (
      var.k3s_server_pool_size +
      (var.k3s_standalone_worker ? 1 : 0)
    ) <= 5
    error_message = "enable_backup = true with the current node count would exceed the Always Free 5-backup limit. Reduce k3s_server_pool_size or disable the standalone worker."
  }
}

check "always_free_ocpu_budget" {
  assert {
    condition = (
      var.k3s_server_pool_size * var.server_ocpus +
      (var.k3s_standalone_worker ? var.worker_ocpus : 0) +
      var.k3s_worker_pool_size * var.worker_ocpus
    ) <= 2
    error_message = "Total OCPU allocation exceeds the Always Free A1.Flex limit of 2 OCPUs. Reduce server_ocpus, worker_ocpus, or the number of nodes."
  }
}

check "always_free_ram_budget" {
  assert {
    condition = (
      var.k3s_server_pool_size * var.server_memory_in_gbs +
      (var.k3s_standalone_worker ? var.worker_memory_in_gbs : 0) +
      var.k3s_worker_pool_size * var.worker_memory_in_gbs
    ) <= 12
    error_message = "Total RAM allocation exceeds the Always Free A1.Flex limit of 12 GB. Reduce server_memory_in_gbs, worker_memory_in_gbs, or the number of nodes."
  }
}

check "always_free_node_count" {
  assert {
    condition = (
      var.k3s_server_pool_size +
      (var.k3s_standalone_worker ? 1 : 0) +
      var.k3s_worker_pool_size
    ) <= 2
    error_message = "Total node count exceeds the Always Free limit of 2 A1.Flex instances. Use k3s_server_pool_size=1 + k3s_standalone_worker=true + k3s_worker_pool_size=0 for the recommended topology."
  }
}

check "always_free_block_storage_budget" {
  assert {
    condition = (
      var.k3s_server_pool_size +
      (var.k3s_standalone_worker ? 1 : 0) +
      var.k3s_worker_pool_size
    ) * var.boot_volume_size_in_gbs <= 200
    error_message = "Total boot volume size (nodes × boot_volume_size_in_gbs) exceeds the Always Free block storage limit of 200 GB. Reduce boot_volume_size_in_gbs."
  }
}

check "expose_ssh_makes_bastion_redundant" {
  assert {
    condition     = !(var.expose_ssh && var.enable_bastion)
    error_message = "expose_ssh = true makes OCI Bastion Service redundant (set enable_bastion = false). Keeping both enabled wastes a Bastion resource and causes 15–30 min VNIC cleanup delays on destroy."
  }
}

check "longhorn_backup_requires_region" {
  assert {
    condition     = !local.longhorn_backup_automated || var.region != null
    error_message = "Automatic Longhorn backup wiring (create_longhorn_backup_user = true or user_ocid set) requires region to be explicitly set. The S3-compatible endpoint URL is region-specific; omitting it would silently use the wrong endpoint and fail all backups."
  }
}

check "longhorn_backup_user_exclusive" {
  assert {
    condition     = !(var.create_longhorn_backup_user && var.user_ocid != null)
    error_message = "create_longhorn_backup_user = true and user_ocid are mutually exclusive: the module creates its own bucket-scoped service user. Unset user_ocid."
  }
}

check "longhorn_backup_user_requires_backup" {
  assert {
    condition     = !var.create_longhorn_backup_user || var.enable_longhorn_backup
    error_message = "create_longhorn_backup_user = true requires enable_longhorn_backup = true (the service user's policy is scoped to the backup bucket)."
  }
}

check "etcd_snapshots_requires_object_storage" {
  assert {
    condition     = !var.enable_etcd_snapshots || var.enable_object_storage_state
    error_message = "enable_etcd_snapshots = true requires enable_object_storage_state = true (the state bucket is used for etcd snapshot uploads via OCI CLI instance_principal)."
  }
}

check "external_secrets_user_requires_external_secrets" {
  assert {
    condition     = !var.create_external_secrets_user || (var.enable_external_secrets && var.enable_vault && var.region != null)
    error_message = "create_external_secrets_user = true requires enable_external_secrets = true, enable_vault = true and region set (the service user reads the module vault, and its ClusterSecretStore needs the region)."
  }
}
