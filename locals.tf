locals {
  # Resolved k3s version: fetched from GitHub at plan-time when var.k3s_version == "latest"
  k3s_version = var.k3s_version == "latest" ? jsondecode(data.http.k3s_latest_release[0].response_body).name : var.k3s_version

  # SSH public key: prefer the string value; fall back to reading the file path
  ssh_public_key = var.public_key != null ? var.public_key : trimspace(file(pathexpand(var.public_key_path)))

  # Applied to every OCI resource for consistent identification and cost tracking
  common_tags = {
    provisioner          = "terraform"
    environment          = var.environment
    k3s-cluster-name     = var.cluster_name
    (var.unique_tag_key) = var.unique_tag_value
  }

  # Shared OCI agent plugin configuration applied to all compute instances
  agent_plugins = [
    { name = "Vulnerability Scanning", desired_state = "DISABLED" },
    { name = "Compute Instance Monitoring", desired_state = "ENABLED" },
    { name = "Custom Logs Monitoring", desired_state = "ENABLED" },
    { name = "Bastion", desired_state = "DISABLED" },
  ]

  # Internal LB IP used as the k3s server URL for agent join
  k3s_internal_lb_ip = oci_load_balancer_load_balancer.k3s_internal_lb.ip_address_details[0].ip_address

  # Public NLB IP (first public address)
  public_lb_ip = [
    for addr in oci_network_load_balancer_network_load_balancer.k3s_public_nlb.ip_addresses :
    addr.ip_address if addr.is_public == true
  ]
}
