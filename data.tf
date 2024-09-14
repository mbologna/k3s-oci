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
      nginx_ingress_release             = var.nginx_ingress_release
      istio_release                     = var.istio_release
      install_certmanager               = var.install_certmanager
      certmanager_release               = var.certmanager_release
      certmanager_email_address         = var.certmanager_email_address
      compartment_ocid                  = var.compartment_ocid
      availability_domain               = var.availability_domain
      cluster_name                      = var.cluster_name
      k3s_url                           = local.k3s_internal_lb_ip
      k3s_tls_san                       = local.k3s_internal_lb_ip
      expose_kubeapi                    = var.expose_kubeapi
      k3s_tls_san_public                = local.public_lb_ip[0]
      install_argocd                    = var.install_argocd
      argocd_release                    = var.argocd_release
      install_argocd_image_updater      = var.install_argocd_image_updater
      argocd_image_updater_release      = var.argocd_image_updater_release
      install_longhorn                  = var.install_longhorn
      longhorn_release                  = var.longhorn_release
      install_kured                     = var.install_kured
      kured_release                     = var.kured_release
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
      k3s_version                       = local.k3s_version
      k3s_subnet                        = var.k3s_subnet
      k3s_token                         = random_password.k3s_token.result
      disable_ingress                   = var.disable_ingress
      k3s_url                           = local.k3s_internal_lb_ip
      cluster_name                      = var.cluster_name
      compartment_ocid                  = var.compartment_ocid
      http_lb_port                      = var.http_lb_port
      https_lb_port                     = var.https_lb_port
      install_longhorn                  = var.install_longhorn
      ingress_controller_http_nodeport  = var.ingress_controller_http_nodeport
      ingress_controller_https_nodeport = var.ingress_controller_https_nodeport
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
