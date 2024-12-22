# OCI Bastion Service — managed SSH proxy (Always Free, no storage)
# When enable_bastion = true, creates a STANDARD bastion associated with the
# private subnet. Sessions originate from within the private subnet CIDR, so
# the k3s node NSGs allow SSH from var.private_subnet_cidr.
#
# Use example/get-kubeconfig.sh (or create sessions manually via OCI CLI) to
# connect to nodes. No public VM, no boot volume, no storage cost.

resource "oci_bastion_bastion" "k3s" {
  count = var.enable_bastion ? 1 : 0

  bastion_type     = "STANDARD"
  compartment_id   = var.compartment_ocid
  target_subnet_id = oci_core_subnet.private.id
  name             = "${var.cluster_name}-bastion"

  client_cidr_block_allow_list = [var.my_public_ip_cidr]

  freeform_tags = local.common_tags
}
