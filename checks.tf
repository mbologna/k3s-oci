# Feature flag dependency checks.
# Uses Terraform 1.9+ check{} blocks (required_version >= 1.9.0) to catch
# invalid variable combinations at plan time with clear error messages,
# before any OCI API call is made.

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
    ) <= 4
    error_message = "Total OCPU allocation exceeds the Always Free A1.Flex limit of 4 OCPUs. Reduce server_ocpus, worker_ocpus, or the number of nodes."
  }
}

check "always_free_ram_budget" {
  assert {
    condition = (
      var.k3s_server_pool_size * var.server_memory_in_gbs +
      (var.k3s_standalone_worker ? var.worker_memory_in_gbs : 0) +
      var.k3s_worker_pool_size * var.worker_memory_in_gbs
    ) <= 24
    error_message = "Total RAM allocation exceeds the Always Free A1.Flex limit of 24 GB. Reduce server_memory_in_gbs, worker_memory_in_gbs, or the number of nodes."
  }
}

check "always_free_node_count" {
  assert {
    condition = (
      var.k3s_server_pool_size +
      (var.k3s_standalone_worker ? 1 : 0) +
      var.k3s_worker_pool_size
    ) <= 4
    error_message = "Total node count exceeds the Always Free limit of 4 A1.Flex instances. Use k3s_server_pool_size=3 + k3s_standalone_worker=true + k3s_worker_pool_size=0 for the recommended topology."
  }
}

check "expose_ssh_makes_bastion_redundant" {
  assert {
    condition     = !(var.expose_ssh && var.enable_bastion)
    error_message = "expose_ssh = true makes OCI Bastion Service redundant (set enable_bastion = false). Keeping both enabled wastes a Bastion resource and causes 15–30 min VNIC cleanup delays on destroy."
  }
}
