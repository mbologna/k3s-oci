# Internal flexible load balancer — routes kubeapi traffic from agents to servers.
# Uses the OCI Always Free 10 Mbps flexible LB (private, not internet-facing).

resource "oci_load_balancer_load_balancer" "k3s_internal_lb" {
  lifecycle {
    ignore_changes  = [network_security_group_ids]
    prevent_destroy = true
  }

  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-internal-lb"
  shape          = "flexible"
  subnet_ids     = [oci_core_subnet.private.id]
  ip_mode        = "IPV4"
  is_private     = true
  freeform_tags  = local.common_tags

  shape_details {
    # 10 Mbps is the Always Free limit for flexible LBs
    minimum_bandwidth_in_mbps = 10
    maximum_bandwidth_in_mbps = 10
  }
}

resource "oci_load_balancer_backend_set" "k3s_kubeapi" {
  load_balancer_id = oci_load_balancer_load_balancer.k3s_internal_lb.id
  name             = "k3s-kubeapi-backend-set"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol          = "HTTPS"
    port              = var.kube_api_port
    url_path          = "/readyz"
    return_code       = 200
    interval_ms       = 5000 # 5 s — default 10 s; reduces UNKNOWN→UNHEALTHY window
    retries           = 2    # 2 failures → UNHEALTHY (default 3); 2×5 s = 10 s vs 30 s
    timeout_in_millis = 3000
    # HTTPS health check: OCI performs TLS handshake then HTTP GET /readyz.
    # The backend TLS cert is NOT verified (OCI flexible LB health checker behaviour).
    # This correctly reflects actual apiserver+etcd health — a server with dead etcd
    # still passes TCP but fails /readyz — ensuring the LB routes kubeapi traffic only
    # to nodes genuinely serving requests.
    # IMPORTANT: must be HTTPS, not HTTP. The k3s apiserver is TLS-only (no plaintext
    # HTTP listener since Kubernetes 1.20). A plaintext GET to port 6443 fails the TLS
    # handshake and never returns 200, leaving all backends permanently UNHEALTHY.
  }
}

resource "oci_load_balancer_listener" "k3s_kubeapi" {
  load_balancer_id         = oci_load_balancer_load_balancer.k3s_internal_lb.id
  default_backend_set_name = oci_load_balancer_backend_set.k3s_kubeapi.name
  name                     = "k3s-kubeapi-listener"
  port                     = var.kube_api_port
  protocol                 = "TCP"
}

resource "oci_load_balancer_backend" "k3s_servers" {
  depends_on = [oci_core_instance_pool.k3s_servers]

  count            = var.k3s_server_pool_size
  load_balancer_id = oci_load_balancer_load_balancer.k3s_internal_lb.id
  backendset_name  = oci_load_balancer_backend_set.k3s_kubeapi.name
  ip_address       = data.oci_core_instance.k3s_servers[count.index].private_ip
  port             = var.kube_api_port
}
