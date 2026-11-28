# OCI Bastion (managed, free): port forwarding into the private subnet for the
# Kubernetes API behind the internal load balancer and break-glass SSH to a node.

resource "oci_bastion_bastion" "this" {
  count = var.enable_bastion ? 1 : 0

  bastion_type                 = "STANDARD"
  compartment_id               = var.compartment_ocid
  target_subnet_id             = oci_core_subnet.private.id
  name                         = replace("${var.cluster_name}-bastion", "-", "")
  client_cidr_block_allow_list = var.bastion_client_cidrs
  max_session_ttl_in_seconds   = 10800
  freeform_tags                = local.common_tags
}
