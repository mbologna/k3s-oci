# ── Public NLB NSG ────────────────────────────────────────────────────────────

resource "oci_core_network_security_group" "public_nlb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k3s.id
  display_name   = "${var.cluster_name}-public-nlb-nsg"
  freeform_tags  = local.common_tags
}

resource "oci_core_network_security_group_security_rule" "nlb_allow_http" {
  network_security_group_id = oci_core_network_security_group.public_nlb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  description               = "Allow HTTP from anywhere"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = var.http_lb_port
      max = var.http_lb_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nlb_allow_https" {
  network_security_group_id = oci_core_network_security_group.public_nlb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  description               = "Allow HTTPS from anywhere"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = var.https_lb_port
      max = var.https_lb_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nlb_allow_kubeapi" {
  count                     = var.expose_kubeapi ? 1 : 0
  network_security_group_id = oci_core_network_security_group.public_nlb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  description               = "Allow kubeapi from operator IP"
  source                    = var.my_public_ip_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = var.kube_api_port
      max = var.kube_api_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nlb_allow_ssh" {
  count                     = var.expose_ssh ? 1 : 0
  network_security_group_id = oci_core_network_security_group.public_nlb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  description               = "Allow SSH from operator IP (expose_ssh=true)"
  source                    = var.my_public_ip_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# ── Workers NSG ───────────────────────────────────────────────────────────────

resource "oci_core_network_security_group" "workers" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k3s.id
  display_name   = "${var.cluster_name}-workers-nsg"
  freeform_tags  = local.common_tags
}

# Both workers and servers are NLB backends with is_preserve_source=true, so
# packets arrive with the real client IP. Shared rules use for_each over
# local.nodes_nsgs to avoid duplicating identical resources per tier.

resource "oci_core_network_security_group_security_rule" "nodes_allow_http" {
  for_each                  = local.nodes_nsgs
  network_security_group_id = each.value
  direction                 = "INGRESS"
  protocol                  = "6"
  # With is_preserve_source = true on the NLB backend sets, packets arrive at
  # nodes with the client's source IP, not the NLB's IP. Nodes are in a private
  # subnet with no public IPs so 0.0.0.0/0 is safe: internet traffic can only
  # enter via the NLB frontend.
  description = "HTTP nodeport – allow internet IPs preserved by NLB source passthrough"
  source      = "0.0.0.0/0"
  source_type = "CIDR_BLOCK"
  stateless   = false

  tcp_options {
    destination_port_range {
      min = var.ingress_controller_http_nodeport
      max = var.ingress_controller_http_nodeport
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nodes_allow_https" {
  for_each                  = local.nodes_nsgs
  network_security_group_id = each.value
  direction                 = "INGRESS"
  protocol                  = "6"
  description               = "HTTPS nodeport – allow internet IPs preserved by NLB source passthrough"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = var.ingress_controller_https_nodeport
      max = var.ingress_controller_https_nodeport
    }
  }
}

# ── Servers NSG (kubeapi from internal LB) ───────────────────────────────────

resource "oci_core_network_security_group" "servers" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k3s.id
  display_name   = "${var.cluster_name}-servers-nsg"
  freeform_tags  = local.common_tags
}

resource "oci_core_network_security_group_security_rule" "servers_allow_kubeapi_internal" {
  network_security_group_id = oci_core_network_security_group.servers.id
  direction                 = "INGRESS"
  protocol                  = "6"
  description               = "kubeapi from internal LB"
  source                    = var.private_subnet_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = var.kube_api_port
      max = var.kube_api_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "servers_allow_kubeapi_public" {
  count                     = var.expose_kubeapi ? 1 : 0
  network_security_group_id = oci_core_network_security_group.servers.id
  direction                 = "INGRESS"
  protocol                  = "6"
  description               = "kubeapi from operator IP via public NLB (expose_kubeapi=true)"
  # NLB uses is_preserve_source=true so the real client IP arrives at the node VNIC,
  # not the NLB IP. NETWORK_SECURITY_GROUP source type only matches the NLB's own
  # health-check traffic. Use CIDR_BLOCK so actual kubeapi connections are allowed.
  source      = var.my_public_ip_cidr
  source_type = "CIDR_BLOCK"
  stateless   = false

  tcp_options {
    destination_port_range {
      min = var.kube_api_port
      max = var.kube_api_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nodes_allow_ssh_from_private_subnet" {
  for_each                  = var.enable_bastion ? local.nodes_nsgs : {}
  network_security_group_id = each.value
  direction                 = "INGRESS"
  protocol                  = "6"
  description               = "SSH from OCI Bastion Service (private subnet)"
  source                    = var.private_subnet_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# NLB uses is_preserve_source = true so nodes see the real client IP — use CIDR_BLOCK rules.
resource "oci_core_network_security_group_security_rule" "nodes_allow_ssh_public" {
  for_each                  = var.expose_ssh ? local.nodes_nsgs : {}
  network_security_group_id = each.value
  direction                 = "INGRESS"
  protocol                  = "6"
  description               = "SSH from operator IP via public NLB (expose_ssh=true)"
  source                    = var.my_public_ip_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}
