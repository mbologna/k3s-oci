# Public network load balancer (the Always Free one): HTTP and HTTPS to the
# ingress controller's NodePorts on every node. is_preserve_source keeps the
# client IP, which the ingress controller sees with externalTrafficPolicy: Local.

locals {
  nlb_ports = {
    http  = { port = 80, nodeport = var.ingress_http_nodeport }
    https = { port = 443, nodeport = var.ingress_https_nodeport }
  }

  nlb_backends = {
    for pair in setproduct(keys(local.nlb_ports), keys(var.nodes)) :
    "${pair[0]}-${pair[1]}" => { listener = pair[0], node = pair[1] }
  }
}

resource "oci_network_load_balancer_network_load_balancer" "public" {
  compartment_id                 = var.compartment_ocid
  display_name                   = "${var.cluster_name}-public-nlb"
  subnet_id                      = oci_core_subnet.public.id
  network_security_group_ids     = [oci_core_network_security_group.public_nlb.id]
  is_private                     = false
  is_preserve_source_destination = false
  freeform_tags                  = local.common_tags
}

resource "oci_network_load_balancer_backend_set" "public" {
  for_each = local.nlb_ports

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.public.id
  name                     = each.key
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = true

  health_checker {
    protocol = "TCP"
    port     = each.value.nodeport
  }
}

resource "oci_network_load_balancer_listener" "public" {
  for_each = local.nlb_ports

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.public.id
  name                     = each.key
  default_backend_set_name = oci_network_load_balancer_backend_set.public[each.key].name
  port                     = each.value.port
  protocol                 = "TCP"
}

# The NLB applies one backend change at a time; the provider retries the
# resulting 409 conflicts.
resource "oci_network_load_balancer_backend" "public" {
  for_each = local.nlb_backends

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.public.id
  backend_set_name         = oci_network_load_balancer_backend_set.public[each.value.listener].name
  name                     = "${each.value.node}-${local.nlb_ports[each.value.listener].nodeport}"
  target_id                = oci_core_instance.node[each.value.node].id
  port                     = local.nlb_ports[each.value.listener].nodeport
}
