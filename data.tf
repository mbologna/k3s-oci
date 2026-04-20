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

data "cloudinit_config" "k3s_server" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/files/k3s-install-server.sh", {
      k3s_version                       = local.k3s_version
      k3s_subnet                        = var.k3s_subnet
      k3s_token                         = random_password.k3s_token.result
      disable_ingress                   = var.disable_ingress
      ingress_controller                = var.ingress_controller
      certmanager_release               = var.certmanager_release
      certmanager_email_address         = var.certmanager_email_address
      compartment_ocid                  = var.compartment_ocid
      availability_domain               = var.availability_domain
      cluster_name                      = var.cluster_name
      k3s_url                           = local.k3s_internal_lb_ip
      k3s_tls_san                       = local.k3s_internal_lb_ip
      expose_kubeapi                    = var.expose_kubeapi
      k3s_tls_san_public                = local.public_lb_ip[0]
      argocd_chart_release              = var.argocd_chart_release
      argocd_image_updater_release      = var.argocd_image_updater_release
      argocd_hostname                   = var.argocd_hostname != null ? var.argocd_hostname : ""
      longhorn_release                  = var.longhorn_release
      longhorn_hostname                 = var.longhorn_hostname != null ? var.longhorn_hostname : ""
      longhorn_ui_username              = var.longhorn_ui_username
      longhorn_ui_password              = random_password.longhorn_ui_password.result
      gitops_repo_url                   = var.gitops_repo_url
      kured_release                     = var.kured_release
      kured_start_time                  = var.kured_start_time
      kured_end_time                    = var.kured_end_time
      kured_reboot_days                 = join(",", var.kured_reboot_days)
      oci_cli_version                   = var.oci_cli_version
      ingress_controller_http_nodeport  = var.ingress_controller_http_nodeport
      ingress_controller_https_nodeport = var.ingress_controller_https_nodeport
    })
  }
}

data "cloudinit_config" "k3s_worker" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/files/k3s-install-agent.sh", {
      k3s_version = local.k3s_version
      k3s_subnet  = var.k3s_subnet
      k3s_token   = random_password.k3s_token.result
      k3s_url     = local.k3s_internal_lb_ip
    })
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
