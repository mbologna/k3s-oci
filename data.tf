data "http" "k3s_latest_release" {
  count = var.k3s_version == "latest" ? 1 : 0
  url   = "https://api.github.com/repos/k3s-io/k3s/releases/latest"

  request_headers = {
    Accept = "application/vnd.github+json"
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "GitHub API returned ${self.status_code} when resolving latest k3s version."
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

data "cloudinit_config" "k3s_server" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = join("\n", [
      templatefile("${path.module}/files/server-vars.sh.tpl", {
        k3s_version                       = local.k3s_version
        k3s_subnet                        = var.k3s_subnet
        k3s_token                         = var.enable_vault ? "" : random_password.k3s_token.result
        k3s_url                           = local.k3s_internal_lb_ip
        k3s_tls_san                       = local.k3s_internal_lb_ip
        k3s_tls_san_public                = try(local.public_lb_ip[0], "")
        expose_kubeapi                    = var.expose_kubeapi
        compartment_ocid                  = var.compartment_ocid
        availability_domain               = var.availability_domain
        cluster_name                      = var.cluster_name
        gitops_repo_url                   = var.gitops_repo_url
        longhorn_ui_username              = var.longhorn_ui_username
        longhorn_ui_password              = var.enable_vault ? "" : random_password.longhorn_ui_password.result
        grafana_admin_password            = var.enable_vault ? "" : random_password.grafana_admin_password.result
        vault_secret_id_k3s_token         = var.enable_vault ? oci_vault_secret.k3s_token[0].id : ""
        vault_secret_id_longhorn_password = var.enable_vault ? oci_vault_secret.longhorn_ui_password[0].id : ""
        vault_secret_id_grafana_password  = var.enable_vault ? oci_vault_secret.grafana_admin_password[0].id : ""
        gateway_api_version               = var.gateway_api_version
        certmanager_email_address         = var.certmanager_email_address
        certmanager_chart_version         = var.certmanager_chart_version
        argocd_chart_version              = var.argocd_chart_version
        enable_external_dns               = var.enable_external_dns
        cloudflare_api_token              = var.cloudflare_api_token != null ? var.cloudflare_api_token : ""
        cloudflare_zone_id                = var.cloudflare_zone_id != null ? var.cloudflare_zone_id : ""
        external_dns_domain_filter        = var.external_dns_domain_filter != null ? var.external_dns_domain_filter : ""
        enable_external_secrets           = var.enable_external_secrets
        vault_ocid                        = var.enable_vault ? oci_kms_vault.k3s[0].id : ""
        oci_region                        = var.region != null ? var.region : ""
        external_secrets_chart_version    = var.external_secrets_chart_version
        enable_dns01_challenge            = var.enable_dns01_challenge
        notification_topic_endpoint       = var.enable_notifications ? oci_ons_notification_topic.k3s_alerts[0].api_endpoint : ""
        mysql_endpoint                    = var.enable_mysql ? "${oci_mysql_mysql_db_system.k3s[0].endpoints[0].hostname}:${oci_mysql_mysql_db_system.k3s[0].endpoints[0].port}" : ""
        mysql_admin_username              = var.enable_mysql ? var.mysql_admin_username : ""
        mysql_admin_password              = var.enable_mysql ? random_password.mysql_admin_password[0].result : ""
      }),
      file("${path.module}/files/lib/common.sh"),
      file("${path.module}/files/lib/k3s-server.sh"),
      file("${path.module}/files/lib/k3s-bootstrap.sh"),
    ])
  }
}

data "cloudinit_config" "k3s_worker" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = join("\n", [
      templatefile("${path.module}/files/agent-vars.sh.tpl", {
        k3s_version               = local.k3s_version
        k3s_subnet                = var.k3s_subnet
        k3s_token                 = var.enable_vault ? "" : random_password.k3s_token.result
        k3s_url                   = local.k3s_internal_lb_ip
        vault_secret_id_k3s_token = var.enable_vault ? oci_vault_secret.k3s_token[0].id : ""
      }),
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
# Auto-resolved from tenancy when os_image_id is not set explicitly.
data "oci_core_images" "k3s_nodes" {
  count                    = var.os_image_id == null ? 1 : 0
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
