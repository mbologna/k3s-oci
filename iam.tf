# Dynamic group covers all instances in the cluster's compartment.
# NOTE: Freeform tags applied by instance pools are NOT indexed by the IAM token
# issuance service, so using instance.freeform_tag in the matching_rule causes
# instance_principal auth to fail with "no groups" for all pool members. Using
# compartment.id alone is the reliable approach — the policy verbs (read
# instance-family, read secret-family, …) are already narrowly scoped.
resource "oci_identity_dynamic_group" "k3s" {
  compartment_id = var.tenancy_ocid
  description    = "k3s cluster '${var.cluster_name}' instances"
  name           = var.oci_identity_dynamic_group_name

  matching_rule = "All {instance.compartment.id = '${var.compartment_ocid}'}"

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
