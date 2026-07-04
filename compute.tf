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
              name          = plugins_config.value.name
              desired_state = plugins_config.value.desired_state
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
        image_id                = local.os_image_id
        boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
      }

      metadata = {
        ssh_authorized_keys = local.ssh_public_key
        user_data           = data.cloudinit_config.k3s_server.rendered
      }

      freeform_tags = merge(local.common_tags, { k3s-instance-type = "k3s-server" })
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [instance_details]
  }

  # OCI's DeleteInstancePool API returns 202 before the backend releases the
  # association with the InstanceConfiguration. Without this wait, a concurrent
  # destroy of the config gets a 409 "still associated to one or more pools".
  # Running before the delete call gives OCI time to finish cleanup.
  provisioner "local-exec" {
    when    = destroy
    command = "echo 'Waiting 90s for OCI to release instance pool association...' && sleep 90"
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
    # create_before_destroy = false (default) — INTENTIONAL.
    # With create_before_destroy = true, OCI creates a new pool before destroying
    # the old one. If the new pool sits in PROVISIONING indefinitely (A1.Flex
    # capacity constraint) and tofu is killed, BOTH pools become deposed objects.
    # Each retry adds another pair, leading to quota exhaustion (50+ pools).
    # With the default false, the old pool is destroyed first so at most one pool
    # can exist in OCI at any given time.
    ignore_changes = [load_balancers, freeform_tags, instance_configuration_id]
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
              name          = plugins_config.value.name
              desired_state = plugins_config.value.desired_state
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
        image_id                = local.os_image_id
        boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
      }

      metadata = {
        ssh_authorized_keys = local.ssh_public_key
        user_data           = data.cloudinit_config.k3s_worker.rendered
      }

      freeform_tags = merge(local.common_tags, { k3s-instance-type = "k3s-worker" })
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [instance_details]
  }

  # Same OCI eventual-consistency workaround as k3s_server config above.
  provisioner "local-exec" {
    when    = destroy
    command = "echo 'Waiting 90s for OCI to release instance pool association...' && sleep 90"
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
    # create_before_destroy = false (default) — same rationale as k3s_servers above.
    ignore_changes = [load_balancers, freeform_tags, instance_configuration_id]
  }
}

# ── Standalone worker node ────────────────────────────────────────────────────
# OCI Always Free A1.Flex capacity is best claimed via a direct oci_core_instance
# rather than an instance pool. Instance pools go through OCI's Capacity Management
# API which can return "out of capacity" errors for A1.Flex on Always Free tenancies.
# With k3s_server_pool_size=1 and k3s_standalone_worker=true this consumes the full
# Always Free budget: 2 × (1 OCPU / 6 GB RAM) = 2 OCPUs / 12 GB.
# OCI reduced the A1.Flex Always Free allocation in June 2026 from 4 OCPUs/24 GB to 2 OCPUs/12 GB.

resource "oci_core_instance" "k3s_standalone_worker" {
  count = var.k3s_standalone_worker ? 1 : 0
  depends_on = [
    oci_load_balancer_load_balancer.k3s_internal_lb,
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
    source_id               = local.os_image_id
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

  lifecycle {
    # metadata: contains user_data (cloud-init) — not re-applied after first boot
    # source_details: OCI provider import does not fully reconstruct nested source_details
    # attributes, causing spurious ForceNew after tofu import. Safe to ignore because
    # boot_volume_size_in_gbs and source_id are immutable post-creation anyway.
    # metadata: contains user_data (cloud-init) — not re-applied after first boot.
    # source_details, create_vnic_details: OCI provider does not reconstruct these
    # nested blocks on import (API returns VNIC/boot-volume data via separate endpoints).
    # All three blocks are effectively immutable post-creation, so ignoring drift is safe.
    # The standalone worker is created via OCI CLI to work around a tls: bad record MAC
    # bug in the OCI Terraform provider (Go HTTP/2 issue on the /instances endpoint).
    # After import, all drift is suppressed so Terraform never modifies or destroys it.
    ignore_changes  = all
    prevent_destroy = false
  }
}

