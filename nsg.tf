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

# ── Workers NSG (HTTP/HTTPS from NLB) ────────────────────────────────────────

resource "oci_core_network_security_group" "workers" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k3s.id
  display_name   = "${var.cluster_name}-workers-nsg"
  freeform_tags  = local.common_tags
}

resource "oci_core_network_security_group_security_rule" "workers_allow_http" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "6"
  description               = "HTTP nodeport from public NLB"
  source                    = oci_core_network_security_group.public_nlb.id
  source_type               = "NETWORK_SECURITY_GROUP"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = var.ingress_controller_http_nodeport
      max = var.ingress_controller_http_nodeport
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_allow_https" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "6"
  description               = "HTTPS nodeport from public NLB"
  source                    = oci_core_network_security_group.public_nlb.id
  source_type               = "NETWORK_SECURITY_GROUP"
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
  description               = "kubeapi from public NLB (expose_kubeapi=true)"
  source                    = oci_core_network_security_group.public_nlb.id
  source_type               = "NETWORK_SECURITY_GROUP"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = var.kube_api_port
      max = var.kube_api_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "servers_allow_ssh_from_private_subnet" {
  count                     = var.enable_bastion ? 1 : 0
  network_security_group_id = oci_core_network_security_group.servers.id
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

resource "oci_core_network_security_group_security_rule" "workers_allow_ssh_from_private_subnet" {
  count                     = var.enable_bastion ? 1 : 0
  network_security_group_id = oci_core_network_security_group.workers.id
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
