# Internal flexible load balancer (the Always Free 10 Mbps one): the cluster
# endpoint for clients, the Kubernetes API (6443) of every server. Nothing
# administrative is public: clients reach it through a Bastion port forward
# (scripts/tunnel.sh). The servers' certificates carry its address.

locals {
  internal_lb_ports = {
    kubeapi = 6443
  }

  internal_lb_backends = {
    for pair in setproduct(keys(local.internal_lb_ports), keys(var.nodes)) :
    "${pair[0]}-${pair[1]}" => { listener = pair[0], node = pair[1] }
  }
}

resource "oci_load_balancer_load_balancer" "internal" {
  compartment_id             = var.compartment_ocid
  display_name               = "${var.cluster_name}-internal-lb"
  shape                      = "flexible"
  subnet_ids                 = [oci_core_subnet.private.id]
  is_private                 = true
  network_security_group_ids = [oci_core_network_security_group.internal_lb.id]
  freeform_tags              = local.common_tags

  shape_details {
    minimum_bandwidth_in_mbps = 10
    maximum_bandwidth_in_mbps = 10
  }
}

resource "oci_load_balancer_backend_set" "internal" {
  for_each = local.internal_lb_ports

  load_balancer_id = oci_load_balancer_load_balancer.internal.id
  name             = each.key
  policy           = "ROUND_ROBIN"

  # TCP: the flexible LB has no HTTPS health check, and the API is TLS-only.
  health_checker {
    protocol          = "TCP"
    port              = each.value
    interval_ms       = 5000
    retries           = 2
    timeout_in_millis = 3000
  }
}

resource "oci_load_balancer_listener" "internal" {
  for_each = local.internal_lb_ports

  load_balancer_id         = oci_load_balancer_load_balancer.internal.id
  name                     = each.key
  default_backend_set_name = oci_load_balancer_backend_set.internal[each.key].name
  port                     = each.value
  protocol                 = "TCP"
}

resource "oci_load_balancer_backend" "internal" {
  for_each = local.internal_lb_backends

  load_balancer_id = oci_load_balancer_load_balancer.internal.id
  backendset_name  = oci_load_balancer_backend_set.internal[each.value.listener].name
  ip_address       = local.node_ips[each.value.node]
  port             = local.internal_lb_ports[each.value.listener]
}
