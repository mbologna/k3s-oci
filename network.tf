resource "oci_core_vcn" "k3s" {
  cidr_block     = var.oci_core_vcn_cidr
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-vcn"
  dns_label      = var.oci_core_vcn_dns_label
  freeform_tags  = local.common_tags
}

resource "oci_core_internet_gateway" "k3s" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-igw"
  enabled        = true
  vcn_id         = oci_core_vcn.k3s.id
  freeform_tags  = local.common_tags
}

resource "oci_core_nat_gateway" "k3s" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-natgw"
  vcn_id         = oci_core_vcn.k3s.id
  freeform_tags  = local.common_tags
}

# Route table for the public subnet → internet
resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k3s.id
  display_name   = "${var.cluster_name}-public-rt"
  freeform_tags  = local.common_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.k3s.id
  }
}

# Route table for the private subnet → NAT gateway (for outbound-only internet)
resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k3s.id
  display_name   = "${var.cluster_name}-private-rt"
  freeform_tags  = local.common_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.k3s.id
  }
}

# Public subnet: load balancers and optional bastion
resource "oci_core_subnet" "public" {
  cidr_block        = var.public_subnet_cidr
  compartment_id    = var.compartment_ocid
  display_name      = "${var.cluster_name}-public-subnet"
  dns_label         = var.public_subnet_dns_label
  vcn_id            = oci_core_vcn.k3s.id
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.public.id]
  freeform_tags     = local.common_tags
}

# Private subnet: k3s nodes (no direct internet ingress)
resource "oci_core_subnet" "private" {
  cidr_block                 = var.private_subnet_cidr
  compartment_id             = var.compartment_ocid
  display_name               = "${var.cluster_name}-private-subnet"
  dns_label                  = var.private_subnet_dns_label
  vcn_id                     = oci_core_vcn.k3s.id
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]
  prohibit_public_ip_on_vnic = true
  freeform_tags              = local.common_tags
}
