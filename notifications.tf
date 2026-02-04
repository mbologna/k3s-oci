# ── OCI Notifications topic for Alertmanager ─────────────────────────────────
# Always Free: 1 million HTTPS notifications + 3,000 email notifications/month.
# Alertmanager posts alerts to the HTTPS endpoint; OCI fans them out to
# email/SMS/PagerDuty/Slack subscriptions.

resource "oci_ons_notification_topic" "k3s_alerts" {
  count          = var.enable_notifications ? 1 : 0
  compartment_id = var.compartment_ocid
  name           = "${var.cluster_name}-alerts"
  description    = "k3s cluster ${var.cluster_name} — Alertmanager webhook"
  freeform_tags  = local.common_tags
}

# Optional email subscription — the subscriber must confirm via the OCI email.
resource "oci_ons_subscription" "alertmanager_email" {
  count          = var.enable_notifications && var.alertmanager_email != null ? 1 : 0
  compartment_id = var.compartment_ocid
  topic_id       = oci_ons_notification_topic.k3s_alerts[0].id
  endpoint       = var.alertmanager_email
  protocol       = "EMAIL"
  freeform_tags  = local.common_tags
}
