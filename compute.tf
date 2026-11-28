# Standalone instances with fixed private IPs: a replaced node keeps its name
# and address. Every node is a k3s server and runs workloads.

resource "oci_core_instance" "node" {
  for_each = var.nodes

  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  fault_domain        = each.value.fault_domain
  display_name        = "${var.cluster_name}-${each.key}"
  shape               = "VM.Standard.A1.Flex"
  freeform_tags       = merge(local.common_tags, { node = each.key })

  shape_config {
    ocpus         = each.value.ocpus
    memory_in_gbs = each.value.memory_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = var.image_id
    boot_volume_size_in_gbs = each.value.boot_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.private.id
    assign_public_ip = false
    private_ip       = local.node_ips[each.key]
    hostname_label   = each.key
    nsg_ids          = [oci_core_network_security_group.nodes.id]
  }

  # The node script holds the k3s token and, with datastore = "mysql", the
  # database password: only principals that can read instance metadata see it,
  # and gitops/network-policies keeps pods away from 169.254.169.254.
  metadata = merge(
    { user_data = local.user_data[each.key] },
    # cloud-init on opensuse reads OCI's key metadata; Ignition takes the key
    # from its own config (nodes.tf).
    var.os_family == "opensuse" && var.ssh_public_key != null ? { ssh_authorized_keys = var.ssh_public_key } : {},
  )

  # cloud-init and Ignition speak IMDSv2 ("Authorization: Bearer Oracle").
  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  availability_config {
    recovery_action = "RESTORE_INSTANCE"
  }

  # Custom images carry no Oracle Cloud Agent.
  agent_config {
    is_management_disabled = true
    is_monitoring_disabled = true
  }

  lifecycle {
    precondition {
      condition     = var.image_id != null
      error_message = "image_id is required to create nodes: run scripts/import-image.sh (or scripts/deploy.sh)."
    }

    precondition {
      condition     = var.os_family != "flatcar" || var.k3s_version != null
      error_message = "os_family = \"flatcar\" needs k3s_version: it names the k3s system extension."
    }

    precondition {
      condition     = var.datastore != "etcd" || contains([1, 3, 5], length(var.nodes))
      error_message = "datastore = \"etcd\" needs 1, 3 or 5 servers (an etcd quorum)."
    }

    # The image is deleted after the deploy, and nodes take changes in place
    # (system-upgrade-controller, the OS's own updates). A replacement is
    # always deliberate: tofu apply -replace.
    ignore_changes = [source_details, metadata]
  }
}
