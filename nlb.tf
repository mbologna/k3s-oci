# Public Network Load Balancer — internet-facing, forwards HTTP/HTTPS to worker nodePorts.
# Uses the OCI Always Free NLB (1 included per tenancy).

resource "oci_network_load_balancer_network_load_balancer" "k3s_public_nlb" {
  lifecycle {
    prevent_destroy = false
  }

  compartment_id                 = var.compartment_ocid
  display_name                   = "${var.cluster_name}-public-nlb"
  subnet_id                      = oci_core_subnet.public.id
  network_security_group_ids     = [oci_core_network_security_group.public_nlb.id]
  is_private                     = false
  is_preserve_source_destination = false
  freeform_tags                  = local.common_tags
}

# ── HTTP + HTTPS ───────────────────────────────────────────────────────────────
# Backend sets and listeners are structurally identical for HTTP and HTTPS;
# only the port numbers differ. Backends are kept as separate resources because
# OCI NLB has a global lifecycle lock (one backend mutation at a time per NLB)
# and must be sequenced via explicit depends_on chains.

locals {
  nlb_web_protocols = {
    http = {
      backend_set_name = "k3s-http-backend"
      listener_name    = "k3s-http-listener"
      frontend_port    = var.http_lb_port
      nodeport         = var.ingress_controller_http_nodeport
    }
    https = {
      backend_set_name = "k3s-https-backend"
      listener_name    = "k3s-https-listener"
      frontend_port    = var.https_lb_port
      nodeport         = var.ingress_controller_https_nodeport
    }
  }
}

resource "oci_network_load_balancer_backend_set" "k3s_web" {
  for_each = local.nlb_web_protocols

  name                     = each.value.backend_set_name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = true

  health_checker {
    protocol = "TCP"
    port     = each.value.nodeport
  }
}

resource "oci_network_load_balancer_listener" "k3s_web" {
  for_each = local.nlb_web_protocols

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  default_backend_set_name = oci_network_load_balancer_backend_set.k3s_web[each.key].name
  name                     = each.value.listener_name
  port                     = each.value.frontend_port
  protocol                 = "TCP"
}

# ── HTTP backends ──────────────────────────────────────────────────────────────
# OCI NLB has a global lifecycle lock: only one backend operation at a time per NLB.
# Chain all backend resource blocks so they execute sequentially and avoid 409 conflicts.

resource "oci_network_load_balancer_backend" "k3s_http_workers" {
  depends_on = [oci_core_instance_pool.k3s_workers]

  count                    = var.k3s_worker_pool_size
  backend_set_name         = oci_network_load_balancer_backend_set.k3s_web["http"].name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  name                     = format("%s:%s", data.oci_core_instance_pool_instances.k3s_workers.instances[count.index].id, var.ingress_controller_http_nodeport)
  port                     = var.ingress_controller_http_nodeport
  target_id                = data.oci_core_instance_pool_instances.k3s_workers.instances[count.index].id
}

resource "oci_network_load_balancer_backend" "k3s_http_standalone_worker" {
  depends_on = [oci_network_load_balancer_backend.k3s_http_workers]

  count = var.k3s_standalone_worker ? 1 : 0

  backend_set_name         = oci_network_load_balancer_backend_set.k3s_web["http"].name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  name                     = format("%s:%s", oci_core_instance.k3s_standalone_worker[0].id, var.ingress_controller_http_nodeport)
  port                     = var.ingress_controller_http_nodeport
  target_id                = oci_core_instance.k3s_standalone_worker[0].id
}

resource "oci_network_load_balancer_backend" "k3s_http_servers" {
  depends_on = [
    oci_core_instance_pool.k3s_servers,
    oci_network_load_balancer_backend.k3s_http_standalone_worker,
    oci_network_load_balancer_backend.k3s_http_workers,
  ]

  count                    = var.k3s_server_pool_size
  backend_set_name         = oci_network_load_balancer_backend_set.k3s_web["http"].name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  name                     = format("%s:%s", data.oci_core_instance_pool_instances.k3s_servers.instances[count.index].id, var.ingress_controller_http_nodeport)
  port                     = var.ingress_controller_http_nodeport
  target_id                = data.oci_core_instance_pool_instances.k3s_servers.instances[count.index].id
}

# ── HTTPS backends ─────────────────────────────────────────────────────────────

resource "oci_network_load_balancer_backend" "k3s_https_workers" {
  depends_on = [
    oci_core_instance_pool.k3s_workers,
    oci_network_load_balancer_backend.k3s_http_servers,
    oci_network_load_balancer_backend.k3s_http_standalone_worker,
  ]

  count                    = var.k3s_worker_pool_size
  backend_set_name         = oci_network_load_balancer_backend_set.k3s_web["https"].name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  name                     = format("%s:%s", data.oci_core_instance_pool_instances.k3s_workers.instances[count.index].id, var.ingress_controller_https_nodeport)
  port                     = var.ingress_controller_https_nodeport
  target_id                = data.oci_core_instance_pool_instances.k3s_workers.instances[count.index].id
}

resource "oci_network_load_balancer_backend" "k3s_https_standalone_worker" {
  depends_on = [
    oci_network_load_balancer_backend.k3s_https_workers,
    oci_network_load_balancer_backend.k3s_http_servers,
  ]

  count = var.k3s_standalone_worker ? 1 : 0

  backend_set_name         = oci_network_load_balancer_backend_set.k3s_web["https"].name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  name                     = format("%s:%s", oci_core_instance.k3s_standalone_worker[0].id, var.ingress_controller_https_nodeport)
  port                     = var.ingress_controller_https_nodeport
  target_id                = oci_core_instance.k3s_standalone_worker[0].id
}

resource "oci_network_load_balancer_backend" "k3s_https_servers" {
  depends_on = [
    oci_core_instance_pool.k3s_servers,
    oci_network_load_balancer_backend.k3s_https_standalone_worker,
    oci_network_load_balancer_backend.k3s_https_workers,
  ]

  count                    = var.k3s_server_pool_size
  backend_set_name         = oci_network_load_balancer_backend_set.k3s_web["https"].name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  name                     = format("%s:%s", data.oci_core_instance_pool_instances.k3s_servers.instances[count.index].id, var.ingress_controller_https_nodeport)
  port                     = var.ingress_controller_https_nodeport
  target_id                = data.oci_core_instance_pool_instances.k3s_servers.instances[count.index].id
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
  depends_on = [
    oci_core_instance_pool.k3s_servers,
    oci_network_load_balancer_backend.k3s_https_servers,
    oci_network_load_balancer_backend.k3s_https_standalone_worker,
  ]

  count = var.expose_kubeapi ? var.k3s_server_pool_size : 0

  backend_set_name         = oci_network_load_balancer_backend_set.k3s_kubeapi_public[0].name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  name                     = format("%s:%s", data.oci_core_instance_pool_instances.k3s_servers.instances[count.index].id, var.kube_api_port)
  port                     = var.kube_api_port
  target_id                = data.oci_core_instance_pool_instances.k3s_servers.instances[count.index].id
}

# ── SSH (optional) ────────────────────────────────────────────────────────────

resource "oci_network_load_balancer_backend_set" "k3s_ssh" {
  count = var.expose_ssh ? 1 : 0

  name                     = "k3s-ssh-backend"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = true

  health_checker {
    protocol = "TCP"
    port     = 22
  }
}

resource "oci_network_load_balancer_listener" "k3s_ssh" {
  count = var.expose_ssh ? 1 : 0

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  default_backend_set_name = oci_network_load_balancer_backend_set.k3s_ssh[0].name
  name                     = "k3s-ssh-listener"
  port                     = 22
  protocol                 = "TCP"
}

resource "oci_network_load_balancer_backend" "k3s_ssh_standalone_worker" {
  depends_on = [
    oci_network_load_balancer_backend.k3s_kubeapi_public_servers,
  ]

  count = var.expose_ssh && var.k3s_standalone_worker ? 1 : 0

  backend_set_name         = oci_network_load_balancer_backend_set.k3s_ssh[0].name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  name                     = format("%s:%s", oci_core_instance.k3s_standalone_worker[0].id, 22)
  port                     = 22
  target_id                = oci_core_instance.k3s_standalone_worker[0].id
}

resource "oci_network_load_balancer_backend" "k3s_ssh_servers" {
  depends_on = [
    oci_core_instance_pool.k3s_servers,
    oci_network_load_balancer_backend.k3s_ssh_standalone_worker,
    oci_network_load_balancer_backend.k3s_kubeapi_public_servers,
  ]

  count = var.expose_ssh ? var.k3s_server_pool_size : 0

  backend_set_name         = oci_network_load_balancer_backend_set.k3s_ssh[0].name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_nlb.id
  name                     = format("%s:%s", data.oci_core_instance_pool_instances.k3s_servers.instances[count.index].id, 22)
  port                     = 22
  target_id                = data.oci_core_instance_pool_instances.k3s_servers.instances[count.index].id
}
