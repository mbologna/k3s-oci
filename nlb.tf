# Public Network Load Balancer — internet-facing, forwards HTTP/HTTPS to worker nodePorts.
# Uses the OCI Always Free NLB (1 included per tenancy).

resource "oci_network_load_balancer_network_load_balancer" "k3s_public_nlb" {
  compartment_id             = var.compartment_ocid
  display_name               = "${var.cluster_name}-public-nlb"
  subnet_id                  = oci_core_subnet.public.id
  network_security_group_ids = [oci_core_network_security_group.public_nlb.id]
  is_private                     = false
  is_preserve_source_destination = false
  freeform_tags                  = local.common_tags
}

# ── HTTP ──────────────────────────────────────────────────────────────────────

resource "oci_network_load_balancer_backend_set" "k3s_http" {
  name                     = "k3s-http-backend"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = true

  health_checker {
    protocol = "TCP"
    port     = var.ingress_controller_http_nodeport
  }
}

resource "oci_network_load_balancer_listener" "k3s_http" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  default_backend_set_name = oci_network_load_balancer_backend_set.k3s_http.name
  name                     = "k3s-http-listener"
  port                     = var.http_lb_port
  protocol                 = "TCP"
}

resource "oci_network_load_balancer_backend" "k3s_http_workers" {
  depends_on = [oci_core_instance_pool.k3s_workers]

  count                    = var.k3s_worker_pool_size
  backend_set_name         = oci_network_load_balancer_backend_set.k3s_http.name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  name                     = format("%s:%s", data.oci_core_instance_pool_instances.k3s_workers.instances[count.index].id, var.ingress_controller_http_nodeport)
  port                     = var.ingress_controller_http_nodeport
  target_id                = data.oci_core_instance_pool_instances.k3s_workers.instances[count.index].id
}

resource "oci_network_load_balancer_backend" "k3s_http_extra_worker" {
  count = var.k3s_extra_worker_node ? 1 : 0

  backend_set_name         = oci_network_load_balancer_backend_set.k3s_http.name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  name                     = format("%s:%s", oci_core_instance.k3s_extra_worker[0].id, var.ingress_controller_http_nodeport)
  port                     = var.ingress_controller_http_nodeport
  target_id                = oci_core_instance.k3s_extra_worker[0].id
}

# ── HTTPS ─────────────────────────────────────────────────────────────────────

resource "oci_network_load_balancer_backend_set" "k3s_https" {
  name                     = "k3s-https-backend"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = true

  health_checker {
    protocol = "TCP"
    port     = var.ingress_controller_https_nodeport
  }
}

resource "oci_network_load_balancer_listener" "k3s_https" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  default_backend_set_name = oci_network_load_balancer_backend_set.k3s_https.name
  name                     = "k3s-https-listener"
  port                     = var.https_lb_port
  protocol                 = "TCP"
}

resource "oci_network_load_balancer_backend" "k3s_https_workers" {
  depends_on = [oci_core_instance_pool.k3s_workers]

  count                    = var.k3s_worker_pool_size
  backend_set_name         = oci_network_load_balancer_backend_set.k3s_https.name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  name                     = format("%s:%s", data.oci_core_instance_pool_instances.k3s_workers.instances[count.index].id, var.ingress_controller_https_nodeport)
  port                     = var.ingress_controller_https_nodeport
  target_id                = data.oci_core_instance_pool_instances.k3s_workers.instances[count.index].id
}

resource "oci_network_load_balancer_backend" "k3s_https_extra_worker" {
  count = var.k3s_extra_worker_node ? 1 : 0

  backend_set_name         = oci_network_load_balancer_backend_set.k3s_https.name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  name                     = format("%s:%s", oci_core_instance.k3s_extra_worker[0].id, var.ingress_controller_https_nodeport)
  port                     = var.ingress_controller_https_nodeport
  target_id                = oci_core_instance.k3s_extra_worker[0].id
}

# ── kubeapi (optional) ────────────────────────────────────────────────────────

resource "oci_network_load_balancer_backend_set" "k3s_kubeapi_public" {
  count = var.expose_kubeapi ? 1 : 0

  name                     = "k3s-kubeapi-public-backend"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = true

  health_checker {
    protocol = "TCP"
    port     = var.kube_api_port
  }
}

resource "oci_network_load_balancer_listener" "k3s_kubeapi_public" {
  count = var.expose_kubeapi ? 1 : 0

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  default_backend_set_name = oci_network_load_balancer_backend_set.k3s_kubeapi_public[0].name
  name                     = "k3s-kubeapi-public-listener"
  port                     = var.kube_api_port
  protocol                 = "TCP"
}

resource "oci_network_load_balancer_backend" "k3s_kubeapi_public_servers" {
  depends_on = [oci_core_instance_pool.k3s_servers]

  count = var.expose_kubeapi ? var.k3s_server_pool_size : 0

  backend_set_name         = oci_network_load_balancer_backend_set.k3s_kubeapi_public[0].name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  name                     = format("%s:%s", data.oci_core_instance_pool_instances.k3s_servers.instances[count.index].id, var.kube_api_port)
  port                     = var.kube_api_port
  target_id                = data.oci_core_instance_pool_instances.k3s_servers.instances[count.index].id
}
