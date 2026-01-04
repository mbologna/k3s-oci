# Security list for the public subnet (LBs + bastion)
resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k3s.id
  display_name   = "${var.cluster_name}-public-sl"
  freeform_tags  = local.common_tags

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    description = "Allow all egress"
  }

  # ICMP from operator IP for diagnostics
  ingress_security_rules {
    protocol    = "1"
    source      = var.my_public_ip_cidr
    description = "ICMP from operator"
  }

  # SSH to bastion only from operator IP
  ingress_security_rules {
    protocol    = "6"
    source      = var.my_public_ip_cidr
    description = "SSH from operator"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # HTTP inbound for the NLB listener
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    description = "HTTP inbound"
    tcp_options {
      min = var.http_lb_port
      max = var.http_lb_port
    }
  }

  # HTTPS inbound for the NLB listener
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    description = "HTTPS inbound"
    tcp_options {
      min = var.https_lb_port
      max = var.https_lb_port
    }
  }
}

# Security list for the private subnet (k3s nodes)
resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k3s.id
  display_name   = "${var.cluster_name}-private-sl"
  freeform_tags  = local.common_tags

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    description = "Allow all egress (via NAT gateway)"
  }

  # ICMP within the VCN
  ingress_security_rules {
    protocol    = "1"
    source      = var.oci_core_vcn_cidr
    description = "ICMP within VCN"
  }

  # All TCP/UDP within the VCN (k3s, etcd, flannel, Longhorn)
  ingress_security_rules {
    protocol    = "all"
    source      = var.oci_core_vcn_cidr
    description = "All traffic within VCN (k3s cluster communication)"
  }
}
