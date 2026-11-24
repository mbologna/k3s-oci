# ── Budget alert ──────────────────────────────────────────────────────────────
# A monthly OCI budget on the whole tenancy, so spend anywhere (not only in this
# module's compartment) is caught: an Always Free deployment should cost nothing.
# Budgets live in the root compartment and are free. They alert; they never stop
# or cap anything. The forecast rule warns while the month can still be saved.

locals {
  budget_alert_rules = {
    "50-percent"           = { type = "ACTUAL", threshold = 50 }
    "100-percent"          = { type = "ACTUAL", threshold = 100 }
    "100-percent-forecast" = { type = "FORECAST", threshold = 100 }
  }
}

resource "oci_budget_budget" "monthly" {
  count          = var.budget_alert_email != null ? 1 : 0
  compartment_id = var.tenancy_ocid
  display_name   = "${var.cluster_name}-monthly-budget"
  description    = "Monthly spend alert for the ${var.cluster_name} Always Free deployment"
  amount         = var.budget_amount
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_ocid]
  freeform_tags  = local.common_tags
}

resource "oci_budget_alert_rule" "monthly" {
  for_each       = var.budget_alert_email != null ? local.budget_alert_rules : {}
  budget_id      = oci_budget_budget.monthly[0].id
  display_name   = "${var.cluster_name}-${each.key}"
  type           = each.value.type
  threshold      = each.value.threshold
  threshold_type = "PERCENTAGE"
  recipients     = var.budget_alert_email
  freeform_tags  = local.common_tags
}
