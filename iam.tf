# Dynamic group is scoped to instances in this compartment tagged with this cluster's name.
# Using the `clustername` freeform tag (hyphen-free key) because OCI's rule language
# does not support hyphenated attribute names. The matching_rule prevents instances from
# other clusters in the same compartment from cross-pollinating IAM permissions.
resource "oci_identity_dynamic_group" "k3s" {
  compartment_id = var.tenancy_ocid
  description    = "k3s cluster '${var.cluster_name}' instances"
  name           = var.oci_identity_dynamic_group_name

  matching_rule = "All {instance.compartment.id = '${var.compartment_ocid}', instance.freeform_tag.clustername = '${var.cluster_name}'}"

  freeform_tags = local.common_tags
}

resource "oci_identity_policy" "k3s" {
  compartment_id = var.compartment_ocid
  description    = "Allow k3s cluster '${var.cluster_name}' instances to read OCI instance metadata"
  name           = var.oci_identity_policy_name

  statements = concat(
    [
      "allow dynamic-group ${oci_identity_dynamic_group.k3s.name} to read instance-family in compartment id ${var.compartment_ocid}",
      "allow dynamic-group ${oci_identity_dynamic_group.k3s.name} to read compute-management-family in compartment id ${var.compartment_ocid}",
      "allow dynamic-group ${oci_identity_dynamic_group.k3s.name} to use log-content in compartment id ${var.compartment_ocid}",
    ],
    var.enable_vault ? [
      "allow dynamic-group ${oci_identity_dynamic_group.k3s.name} to read secret-family in compartment id ${var.compartment_ocid}",
    ] : []
  )

  freeform_tags = local.common_tags
}
