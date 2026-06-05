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
    condition = !var.enable_backup || (
      var.k3s_server_pool_size +
      (var.k3s_standalone_worker ? 1 : 0) +
      (var.k3s_worker_pool_size > 0 ? var.k3s_worker_pool_size : 0)
    ) <= 5
    error_message = "enable_backup = true with the current node count would exceed the Always Free 5-backup limit. Reduce k3s_server_pool_size or disable the standalone worker."
  }
}
