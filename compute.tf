# ── Shared instance configuration template ────────────────────────────────────

locals {
  # Reusable agent_config block for all compute resources
  agent_config = {
    is_management_disabled = false
    is_monitoring_disabled = false
    plugins_config         = local.agent_plugins
  }
}

# ── Server instance configuration (used by the instance pool) ─────────────────

resource "oci_core_instance_configuration" "k3s_server" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-server-config"
  freeform_tags  = merge(local.common_tags, { k3s-instance-type = "k3s-server" })

  instance_details {
    instance_type = "compute"

    launch_details {
      compartment_id      = var.compartment_ocid
      availability_domain = var.availability_domain
      display_name        = "${var.cluster_name}-server"

      dynamic "agent_config" {
        for_each = [local.agent_config]
        content {
          is_management_disabled = agent_config.value.is_management_disabled
          is_monitoring_disabled = agent_config.value.is_monitoring_disabled

          dynamic "plugins_config" {
            for_each = agent_config.value.plugins_config
            content {
              desired_state = plugins_config.value.desired_state
              name          = plugins_config.value.name
            }
          }
        }
      }

      shape = var.compute_shape
      shape_config {
        ocpus         = var.server_ocpus
        memory_in_gbs = var.server_memory_in_gbs
      }

      create_vnic_details {
        assign_public_ip = false
        subnet_id        = oci_core_subnet.private.id
        nsg_ids          = [oci_core_network_security_group.servers.id]
      }

      source_details {
        source_type             = "image"
        image_id                = var.os_image_id
        boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
      }

      metadata = {
        ssh_authorized_keys = local.ssh_public_key
        user_data           = data.cloudinit_config.k3s_server.rendered
      }

      freeform_tags = merge(local.common_tags, { k3s-instance-type = "k3s-server" })
    }
  }
}

# ── Server instance pool ───────────────────────────────────────────────────────

resource "oci_core_instance_pool" "k3s_servers" {
  depends_on = [
    oci_identity_dynamic_group.k3s,
    oci_identity_policy.k3s,
  ]

  compartment_id            = var.compartment_ocid
  display_name              = "${var.cluster_name}-servers"
  instance_configuration_id = oci_core_instance_configuration.k3s_server.id
  size                      = var.k3s_server_pool_size
  freeform_tags             = merge(local.common_tags, { k3s-instance-type = "k3s-server" })

  placement_configurations {
    availability_domain = var.availability_domain
    primary_subnet_id   = oci_core_subnet.private.id
    fault_domains       = var.fault_domains
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [load_balancers, freeform_tags, instance_configuration_id]
  }
}

# ── Worker instance configuration (used by the instance pool) ─────────────────

resource "oci_core_instance_configuration" "k3s_worker" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-worker-config"
  freeform_tags  = merge(local.common_tags, { k3s-instance-type = "k3s-worker" })

  instance_details {
    instance_type = "compute"

    launch_details {
      compartment_id      = var.compartment_ocid
      availability_domain = var.availability_domain
      display_name        = "${var.cluster_name}-worker"

      dynamic "agent_config" {
        for_each = [local.agent_config]
        content {
          is_management_disabled = agent_config.value.is_management_disabled
          is_monitoring_disabled = agent_config.value.is_monitoring_disabled

          dynamic "plugins_config" {
            for_each = agent_config.value.plugins_config
            content {
              desired_state = plugins_config.value.desired_state
              name          = plugins_config.value.name
            }
          }
        }
      }

      shape = var.compute_shape
      shape_config {
        ocpus         = var.worker_ocpus
        memory_in_gbs = var.worker_memory_in_gbs
      }

      create_vnic_details {
        assign_public_ip = false
        subnet_id        = oci_core_subnet.private.id
        nsg_ids          = [oci_core_network_security_group.workers.id]
      }

      source_details {
        source_type             = "image"
        image_id                = var.os_image_id
        boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
      }

      metadata = {
        ssh_authorized_keys = local.ssh_public_key
        user_data           = data.cloudinit_config.k3s_worker.rendered
      }

      freeform_tags = merge(local.common_tags, { k3s-instance-type = "k3s-worker" })
    }
  }
}

# ── Worker instance pool ───────────────────────────────────────────────────────
# Pool size is 0 by default. Kept so the NLB backend set can reference pool-managed
# workers if you ever scale beyond the Always Free limit (k3s_worker_pool_size > 0).

resource "oci_core_instance_pool" "k3s_workers" {
  depends_on = [oci_load_balancer_load_balancer.k3s_internal_lb]

  compartment_id            = var.compartment_ocid
  display_name              = "${var.cluster_name}-workers"
  instance_configuration_id = oci_core_instance_configuration.k3s_worker.id
  size                      = var.k3s_worker_pool_size
  freeform_tags             = merge(local.common_tags, { k3s-instance-type = "k3s-worker" })

  placement_configurations {
    availability_domain = var.availability_domain
    primary_subnet_id   = oci_core_subnet.private.id
    fault_domains       = var.fault_domains
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [load_balancers, freeform_tags, instance_configuration_id]
  }
}

# ── Standalone worker node ────────────────────────────────────────────────────
# OCI Always Free A1.Flex capacity is best claimed via a direct oci_core_instance
# rather than an instance pool. Instance pools go through OCI's Capacity Management
# API which can return "out of capacity" errors for A1.Flex on Always Free tenancies.
# With k3s_server_pool_size=3 and k3s_standalone_worker=true this consumes the full
# Always Free budget: 4 × (1 OCPU / 6 GB RAM) = 4 OCPUs / 24 GB.

resource "oci_core_instance" "k3s_standalone_worker" {
  count = var.k3s_standalone_worker ? 1 : 0
  depends_on = [
    oci_load_balancer_load_balancer.k3s_internal_lb,
    oci_core_instance_pool.k3s_workers,
  ]

  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = "${var.cluster_name}-standalone-worker"
  freeform_tags       = merge(local.common_tags, { k3s-instance-type = "k3s-worker" })

  dynamic "agent_config" {
    for_each = [local.agent_config]
    content {
      is_management_disabled = agent_config.value.is_management_disabled
      is_monitoring_disabled = agent_config.value.is_monitoring_disabled

      dynamic "plugins_config" {
        for_each = agent_config.value.plugins_config
        content {
          desired_state = plugins_config.value.desired_state
          name          = plugins_config.value.name
        }
      }
    }
  }

  shape = var.compute_shape
  shape_config {
    ocpus         = var.worker_ocpus
    memory_in_gbs = var.worker_memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = var.os_image_id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  create_vnic_details {
    assign_private_dns_record = true
    assign_public_ip          = false
    subnet_id                 = oci_core_subnet.private.id
    nsg_ids                   = [oci_core_network_security_group.workers.id]
    hostname_label            = "${var.cluster_name}-standalone-worker"
  }

  metadata = {
    ssh_authorized_keys = local.ssh_public_key
    user_data           = data.cloudinit_config.k3s_worker.rendered
  }
}

# ── Bastion host (optional, VM.Standard.E2.1.Micro — Always Free) ─────────────

resource "oci_core_instance" "bastion" {
  count = var.enable_bastion ? 1 : 0

  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = "${var.cluster_name}-bastion"
  freeform_tags       = merge(local.common_tags, { k3s-instance-type = "bastion" })

  shape = var.bastion_shape

  source_details {
    source_type             = "image"
    source_id               = var.os_image_id
    boot_volume_size_in_gbs = 47
  }

  create_vnic_details {
    assign_public_ip          = true
    assign_private_dns_record = true
    subnet_id                 = oci_core_subnet.public.id
    nsg_ids                   = [oci_core_network_security_group.bastion[0].id]
    hostname_label            = "${var.cluster_name}-bastion"
  }

  metadata = {
    ssh_authorized_keys = local.ssh_public_key
  }
}
