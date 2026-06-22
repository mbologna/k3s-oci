data "http" "k3s_channel" {
  count = contains(["stable", "latest"], var.k3s_version) ? 1 : 0
  url   = "https://update.k3s.io/v1-release/channels/${var.k3s_version}"

  request_headers = {
    Accept = "application/json"
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "k3s channel API returned ${self.status_code} when resolving '${var.k3s_version}' channel."
    }
  }
}

data "http" "github_ssh_keys" {
  count = var.github_ssh_keys_username != "" ? 1 : 0
  url   = "https://github.com/${var.github_ssh_keys_username}.keys"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Failed to fetch SSH keys for GitHub user '${var.github_ssh_keys_username}' (HTTP ${self.status_code})."
    }
  }
}

# Shared SSH host key distributed to all nodes so that SSHing through the NLB
# always presents the same fingerprint regardless of which backend is selected.
resource "tls_private_key" "ssh_host_key" {
  algorithm = "ED25519"
}

resource "random_password" "k3s_token" {
  length  = 64
  special = false

  # Only regenerate the token when the cluster identity changes, not on unrelated variable updates
  keepers = {
    cluster_name = var.cluster_name
  }
}

resource "random_password" "longhorn_ui_password" {
  length  = 24
  special = false

  keepers = {
    cluster_name = var.cluster_name
  }
}

resource "random_password" "grafana_admin_password" {
  length  = 24
  special = false

  keepers = {
    cluster_name = var.cluster_name
  }
}

# ── Server cloud-init vars (thematic locals for readability) ──────────────────
# These are merged on top of local.k3s_common_cloud_init_vars in the templatefile call.

locals {
  # Cluster identity and networking
  _server_identity_vars = {
    k3s_tls_san         = local.k3s_internal_lb_ip
    k3s_tls_san_public  = try(local.public_lb_ip[0], "")
    expose_kubeapi      = var.expose_kubeapi
    compartment_ocid    = var.compartment_ocid
    availability_domain = var.availability_domain
    cluster_name        = var.cluster_name
  }

  # GitOps source and deploy key
  _server_gitops_vars = {
    gitops_repo_url                = var.gitops_repo_url
    gitops_path                    = var.gitops_path
    vault_secret_id_gitops_ssh_key = var.enable_vault && var.gitops_ssh_private_key != "" ? try(oci_vault_secret.gitops_ssh_key[0].id, "") : ""
  }

  # Bootstrap chart versions (cloud-init installs; ArgoCD adopts ongoing management)
  _server_bootstrap_vars = {
    gateway_api_version            = var.gateway_api_version
    certmanager_email_address      = var.certmanager_email_address
    certmanager_chart_version      = var.certmanager_chart_version
    argocd_chart_version           = var.argocd_chart_version
    external_secrets_chart_version = var.external_secrets_chart_version
  }

  # Cluster secrets: plain-text fallback (empty when vault is enabled)
  _server_secret_vars = {
    longhorn_ui_username              = var.longhorn_ui_username
    longhorn_ui_password              = var.enable_vault ? "" : random_password.longhorn_ui_password.result
    grafana_admin_password            = var.enable_vault ? "" : random_password.grafana_admin_password.result
    vault_secret_id_longhorn_password = var.enable_vault ? try(oci_vault_secret.cluster["longhorn_ui_password"].id, "") : ""
    vault_secret_id_grafana_password  = var.enable_vault ? try(oci_vault_secret.cluster["grafana_admin_password"].id, "") : ""
    vault_ocid                        = var.enable_vault ? oci_kms_vault.k3s[0].id : ""
  }

  # Feature flags
  _server_feature_vars = {
    enable_external_dns     = var.enable_external_dns
    enable_external_secrets = var.enable_external_secrets
    enable_dns01_challenge  = var.enable_dns01_challenge
  }

  # Optional integrations (Cloudflare, MySQL, Notifications, DockerHub)
  _server_optional_vars = {
    # Cloudflare: plaintext only when vault is disabled; vault secret ID used otherwise.
    cloudflare_api_token        = var.enable_vault ? "" : coalesce(var.cloudflare_api_token, "")
    cloudflare_zone_id          = var.cloudflare_zone_id != null ? var.cloudflare_zone_id : ""
    external_dns_domain_filter  = var.external_dns_domain_filter != null ? var.external_dns_domain_filter : ""
    vault_secret_id_cloudflare  = var.enable_vault && var.cloudflare_api_token != null ? oci_vault_secret.cloudflare_api_token[0].id : ""
    oci_region                  = coalesce(var.region, "")
    notification_topic_endpoint = var.enable_notifications ? oci_ons_notification_topic.k3s_alerts[0].api_endpoint : ""
    mysql_endpoint              = var.enable_mysql ? "${oci_mysql_mysql_db_system.k3s[0].endpoints[0].hostname}:${oci_mysql_mysql_db_system.k3s[0].endpoints[0].port}" : ""
    mysql_admin_username        = var.enable_mysql ? var.mysql_admin_username : ""
    mysql_admin_password        = var.enable_mysql ? random_password.mysql_admin_password[0].result : ""
    dockerhub_username          = var.dockerhub_username
    # DockerHub password: plaintext only when vault is disabled or not set.
    # When vault is enabled and a password is configured, the plaintext is blanked here
    # and create_dockerhub_secret() in k3s-argocd.sh fetches it from Vault instead.
    dockerhub_password        = var.enable_vault && var.dockerhub_password != "" ? "" : var.dockerhub_password
    vault_secret_id_dockerhub = var.enable_vault && var.dockerhub_password != "" ? oci_vault_secret.dockerhub_password[0].id : ""
  }

  # etcd snapshot upload and Longhorn backup target vars
  _server_backup_vars = {
    enable_etcd_snapshots   = var.enable_etcd_snapshots
    etcd_snapshot_bucket    = var.enable_etcd_snapshots && var.enable_object_storage_state ? "${var.cluster_name}-terraform-state" : ""
    etcd_snapshot_retention = var.etcd_snapshot_retention
    oci_object_namespace    = local.oci_object_namespace
    # Separate lock bucket: driven by enable_object_storage_state alone, independent of
    # enable_etcd_snapshots. Disabling etcd snapshots must NOT disable split-brain protection.
    cluster_lock_bucket    = var.enable_object_storage_state ? "${var.cluster_name}-terraform-state" : ""
    enable_longhorn_backup = var.enable_longhorn_backup
    longhorn_backup_bucket = var.enable_longhorn_backup ? "${var.cluster_name}-longhorn-backup" : ""
    # S3-compatible endpoint for Longhorn backup: auto-set when user_ocid is provided.
    # region is required when enable_longhorn_backup && user_ocid != null (enforced by
    # the longhorn_backup_requires_region check block in checks.tf).
    longhorn_backup_endpoint   = var.enable_longhorn_backup && var.user_ocid != null ? "https://${local.oci_object_namespace}.compat.objectstorage.${var.region}.oraclecloud.com" : ""
    longhorn_backup_access_key = var.enable_longhorn_backup && var.user_ocid != null ? try(oci_identity_customer_secret_key.longhorn_backup[0].id, "") : ""
    longhorn_backup_secret_key = var.enable_longhorn_backup && var.user_ocid != null ? try(oci_identity_customer_secret_key.longhorn_backup[0].key, "") : ""
  }

  # Hostname vars: IP-specific, derived at plan time from the NLB IP
  _server_hostname_vars = {
    grafana_hostname  = local.grafana_hostname
    argocd_hostname   = local.argocd_hostname
    longhorn_hostname = local.longhorn_hostname
  }

  # Debug
  _server_debug_vars = {
    trace_enabled = var.trace_enabled
  }

  # OS family vars: controls bootstrap script selection and SSH user.
  _server_os_vars = {
    os_family      = var.os_family
    os_user        = local.os_user
    ssh_public_key = local.ssh_public_key
  }

  # Final merged map passed to the server templatefile
  k3s_server_cloud_init_vars = merge(
    local.k3s_common_cloud_init_vars,
    local._server_identity_vars,
    local._server_gitops_vars,
    local._server_bootstrap_vars,
    local._server_secret_vars,
    local._server_feature_vars,
    local._server_optional_vars,
    local._server_backup_vars,
    local._server_hostname_vars,
    local._server_debug_vars,
    local._server_os_vars,
  )
}

data "cloudinit_config" "k3s_server" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = join("\n", [
      templatefile("${path.module}/files/server-vars.sh.tpl", local.k3s_server_cloud_init_vars),
      var.os_family == "opensuse" ? file("${path.module}/files/lib/bootstrap-opensuse.sh") : file("${path.module}/files/lib/bootstrap-ubuntu.sh"),
      file("${path.module}/files/lib/common.sh"),
      file("${path.module}/files/lib/k3s-secrets.sh"),
      file("${path.module}/files/lib/k3s-cert-manager.sh"),
      file("${path.module}/files/lib/k3s-external-secrets.sh"),
      file("${path.module}/files/lib/k3s-argocd.sh"),
      file("${path.module}/files/lib/k3s-bootstrap.sh"),
      file("${path.module}/files/lib/k3s-server.sh"),
    ])
  }
}

data "cloudinit_config" "k3s_worker" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = join("\n", [
      templatefile("${path.module}/files/agent-vars.sh.tpl", merge(local.k3s_common_cloud_init_vars, {
        trace_enabled  = var.trace_enabled
        os_family      = var.os_family
        os_user        = local.os_user
        ssh_public_key = local.ssh_public_key
      })),
      var.os_family == "opensuse" ? file("${path.module}/files/lib/bootstrap-opensuse.sh") : file("${path.module}/files/lib/bootstrap-ubuntu.sh"),
      file("${path.module}/files/lib/common.sh"),
      file("${path.module}/files/lib/k3s-agent.sh"),
    ])
  }
}


data "oci_core_instance_pool_instances" "k3s_servers" {
  depends_on       = [oci_core_instance_pool.k3s_servers]
  compartment_id   = var.compartment_ocid
  instance_pool_id = oci_core_instance_pool.k3s_servers.id
}

data "oci_core_instance" "k3s_servers" {
  count       = var.k3s_server_pool_size
  instance_id = data.oci_core_instance_pool_instances.k3s_servers.instances[count.index].id
}

data "oci_core_instance_pool_instances" "k3s_workers" {
  depends_on       = [oci_core_instance_pool.k3s_workers]
  compartment_id   = var.compartment_ocid
  instance_pool_id = oci_core_instance_pool.k3s_workers.id
}

data "oci_core_instance" "k3s_workers" {
  count       = var.k3s_worker_pool_size
  instance_id = data.oci_core_instance_pool_instances.k3s_workers.instances[count.index].id
}

# ── k3s node image (Ubuntu 24.04 aarch64 — A1.Flex) ──────────────────────────
# Auto-resolved from tenancy when os_family = "ubuntu" and os_image_id is not set.
# For os_family = "opensuse", set os_image_id explicitly (use scripts/import-opensuse-aarch64.sh).
data "oci_core_images" "k3s_nodes" {
  count                    = var.os_family == "ubuntu" && var.os_image_id == null ? 1 : 0
  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.compute_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  lifecycle {
    postcondition {
      condition     = length(self.images) > 0
      error_message = "No Ubuntu 24.04 image found for shape ${var.compute_shape} in tenancy. Set os_image_id explicitly."
    }
  }
}
