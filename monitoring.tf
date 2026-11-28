# Free, outside-in signals that don't depend on the cluster: OCI Monitoring
# alarms on hypervisor and load balancer metrics, and an APM synthetic check,
# all to one Notifications topic. Enabled by alert_email.

locals {
  monitoring = var.alert_email != null
}

resource "oci_ons_notification_topic" "alerts" {
  count = local.monitoring ? 1 : 0

  compartment_id = var.compartment_ocid
  name           = "${var.cluster_name}-alerts"
  freeform_tags  = local.common_tags
}

resource "oci_ons_subscription" "email" {
  count = local.monitoring ? 1 : 0

  compartment_id = var.compartment_ocid
  topic_id       = oci_ons_notification_topic.alerts[0].id
  protocol       = "EMAIL"
  endpoint       = var.alert_email
  freeform_tags  = local.common_tags
}

# instance_status: 0 = up, 1 = down from an infrastructure issue (no data
# while the instance is stopped). Hypervisor-side, no agent needed.
resource "oci_monitoring_alarm" "instance_down" {
  count = local.monitoring ? 1 : 0

  compartment_id                                = var.compartment_ocid
  metric_compartment_id                         = var.compartment_ocid
  display_name                                  = "${var.cluster_name}-instance-down"
  namespace                                     = "oci_compute_infrastructure_health"
  query                                         = "instance_status[1m]{resourceDisplayName =~ \"${var.cluster_name}-*\"}.max() == 1"
  severity                                      = "CRITICAL"
  pending_duration                              = "PT5M"
  is_enabled                                    = true
  destinations                                  = [oci_ons_notification_topic.alerts[0].id]
  message_format                                = "ONS_OPTIMIZED"
  repeat_notification_duration                  = "PT4H"
  is_notifications_per_metric_dimension_enabled = true
  body                                          = "A ${var.cluster_name} node is down because of an infrastructure issue."
  freeform_tags                                 = local.common_tags
}

resource "oci_monitoring_alarm" "nlb_unhealthy" {
  count = local.monitoring ? 1 : 0

  compartment_id               = var.compartment_ocid
  metric_compartment_id        = var.compartment_ocid
  display_name                 = "${var.cluster_name}-nlb-unhealthy-backends"
  namespace                    = "oci_nlb"
  query                        = "UnhealthyBackendsPerNlb[5m]{resourceId = \"${oci_network_load_balancer_network_load_balancer.public.id}\"}.max() > 0"
  severity                     = "WARNING"
  pending_duration             = "PT15M"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts[0].id]
  message_format               = "ONS_OPTIMIZED"
  repeat_notification_duration = "PT12H"
  body                         = "The ${var.cluster_name} public NLB has unhealthy backends: an ingress controller pod or a node is not answering on its NodePort. Planned reboots clear within minutes."
  freeform_tags                = local.common_tags
}

# ── APM synthetic uptime check (free tier: 10 runs an hour) ──────────────────

resource "oci_apm_apm_domain" "this" {
  count = local.monitoring && length(var.uptime_urls) > 0 ? 1 : 0

  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-apm"
  is_free_tier   = true
  freeform_tags  = local.common_tags
}

data "oci_apm_synthetics_public_vantage_points" "this" {
  count = length(oci_apm_apm_domain.this)

  apm_domain_id = oci_apm_apm_domain.this[0].id
}

resource "oci_apm_synthetics_monitor" "uptime" {
  for_each = length(oci_apm_apm_domain.this) > 0 ? toset(var.uptime_urls) : toset([])

  apm_domain_id              = oci_apm_apm_domain.this[0].id
  display_name               = "${var.cluster_name}-uptime-${substr(sha1(each.key), 0, 8)}"
  monitor_type               = "REST"
  repeat_interval_in_seconds = 600
  target                     = each.key
  status                     = "ENABLED"
  timeout_in_seconds         = 60
  freeform_tags              = local.common_tags

  vantage_points {
    name = data.oci_apm_synthetics_public_vantage_points.this[0].public_vantage_point_collection[0].items[0].name
  }

  configuration {
    config_type                       = "REST_CONFIG"
    request_method                    = "GET"
    is_redirection_enabled            = true
    is_certificate_validation_enabled = true
    verify_response_codes             = ["200"]
  }
}

resource "oci_monitoring_alarm" "uptime" {
  count = length(oci_apm_synthetics_monitor.uptime) > 0 ? 1 : 0

  compartment_id               = var.compartment_ocid
  metric_compartment_id        = var.compartment_ocid
  display_name                 = "${var.cluster_name}-uptime-check-failing"
  namespace                    = "oracle_apm_synthetics"
  query                        = "Availability[10m]{ResourceId = \"${oci_apm_apm_domain.this[0].id}\"}.mean() < 1"
  severity                     = "CRITICAL"
  pending_duration             = "PT20M"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts[0].id]
  message_format               = "ONS_OPTIMIZED"
  repeat_notification_duration = "PT4H"
  body                         = "The ${var.cluster_name} uptime check is failing from OCI's vantage point."
  freeform_tags                = local.common_tags
}
