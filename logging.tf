# ── OCI Logging ───────────────────────────────────────────────────────────────
# Ships /var/log/k3s-cloud-init.log from every node to OCI Logging Service.
# Logs survive instance replacement; viewable in OCI Console → Observability → Logging.
#
# Requires the OCI Unified Monitoring Agent (oracle-cloud-agent) to be enabled.
# The agent is pre-installed on OCI Ubuntu platform images.

variable "enable_oci_logging" {
  type        = bool
  description = "Enable OCI Logging for cloud-init logs. Ships /var/log/k3s-cloud-init.log to OCI Logging Service via the Unified Monitoring Agent (Always Free: 10 GB/month)."
  default     = true
}

resource "oci_logging_log_group" "k3s" {
  count          = var.enable_oci_logging ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-logs"
  description    = "Cloud-init logs for k3s cluster '${var.cluster_name}'"
  freeform_tags  = local.common_tags

  # OCI's control plane is eventually consistent: even after the log and
  # unified_agent_configuration are deleted (which Terraform does first),
  # the log group deletion returns 409 or silently fails because OCI hasn't
  # fully de-associated them internally. Waiting before the DELETE call gives
  # OCI time to propagate the child deletions, preventing log group orphans
  # after tofu destroy.
  provisioner "local-exec" {
    when    = destroy
    command = "echo 'Waiting 180s for OCI to propagate log/agent-config deletion before removing log group...' && sleep 180"
  }
}

resource "oci_logging_log" "cloud_init" {
  count         = var.enable_oci_logging ? 1 : 0
  display_name  = "${var.cluster_name}-cloud-init"
  log_group_id  = oci_logging_log_group.k3s[0].id
  log_type      = "CUSTOM"
  freeform_tags = local.common_tags

  is_enabled         = true
  retention_duration = 30
}

resource "oci_logging_unified_agent_configuration" "k3s_cloud_init" {
  count          = var.enable_oci_logging ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-cloud-init-agent-config"
  description    = "Ship k3s cloud-init logs to OCI Logging"
  is_enabled     = true
  freeform_tags  = local.common_tags

  group_association {
    group_list = [oci_identity_dynamic_group.k3s.id]
  }

  service_configuration {
    configuration_type = "LOGGING"

    destination {
      log_object_id = oci_logging_log.cloud_init[0].id
    }

    sources {
      source_type = "LOG_TAIL"
      name        = "k3s-cloud-init"
      paths       = ["/var/log/k3s-cloud-init.log"]
      parser {
        parser_type = "NONE"
      }
    }
  }
}

output "oci_log_group_id" {
  description = "OCI Log Group OCID for k3s cloud-init logs (null if enable_oci_logging = false)"
  value       = var.enable_oci_logging ? oci_logging_log_group.k3s[0].id : null
}
