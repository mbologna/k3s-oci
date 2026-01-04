# Dynamic group is scoped to instances tagged with this cluster's name,
# so multiple clusters in the same compartment don't cross-pollinate permissions.
resource "oci_identity_dynamic_group" "k3s" {
  compartment_id = var.tenancy_ocid
  description    = "k3s cluster '${var.cluster_name}' instances"
  name           = var.oci_identity_dynamic_group_name

  matching_rule = "All {instance.compartment.id = '${var.compartment_ocid}', tag.freeformTags.k3s-cluster-name = '${var.cluster_name}'}"

  freeform_tags = local.common_tags
}

resource "oci_identity_policy" "k3s" {
  compartment_id = var.compartment_ocid
  description    = "Allow k3s cluster '${var.cluster_name}' instances to read OCI instance metadata"
  name           = var.oci_identity_policy_name

  statements = [
    "allow dynamic-group ${oci_identity_dynamic_group.k3s.name} to read instance-family in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.k3s.name} to read compute-management-family in compartment id ${var.compartment_ocid}",
  ]

  freeform_tags = local.common_tags
}
