# Dynamic group covers all instances in the cluster's compartment.
# NOTE: Freeform tags applied by instance pools are NOT indexed by the IAM token
# issuance service, so using instance.freeform_tag in the matching_rule causes
# instance_principal auth to fail with "no groups" for all pool members. Using
# compartment.id alone is the reliable approach — the policy verbs (read
# instance-family, read secret-family, …) are already narrowly scoped.
#
# ⚠️  SECURITY: This dynamic group matches ALL instances in the compartment,
# not just k3s cluster members. Every instance in the compartment receives the
# permissions below. Isolate each cluster in its own dedicated compartment to
# prevent cross-cluster secret access.
#
# For shared-compartment deployments, defined-tag scoping provides finer control:
#   matching_rule = "All {instance.compartment.id = '${var.compartment_ocid}',
#                        tag.<namespace>.<key>.value = '${var.cluster_name}'}"
# This requires a Defined Tag namespace (free tier, no cost), and the tag must
# be applied to all cluster instances via compute.tf freeform_tags or defined_tags.
# See: https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/managingdynamicgroups.htm
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
    ] : [],
    # etcd snapshot uploads and leader-lock sentinel: the first server needs to
    # PUT/GET/DELETE objects in the state bucket (using OCI CLI instance_principal,
    # no Customer Secret Keys required).
    var.enable_object_storage_state ? [
      "allow dynamic-group ${oci_identity_dynamic_group.k3s.name} to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name = '${var.cluster_name}-terraform-state'",
    ] : [],
    # Longhorn backup target: Longhorn controller (and setup scripts) need to
    # create/read/delete objects in the dedicated backup bucket.
    var.enable_longhorn_backup ? [
      "allow dynamic-group ${oci_identity_dynamic_group.k3s.name} to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name = '${var.cluster_name}-longhorn-backup'",
    ] : [],
  )

  freeform_tags = local.common_tags
}
