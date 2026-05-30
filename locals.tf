locals {
  # Resolved k3s version: fetched from GitHub at plan-time when var.k3s_version == "latest"
  k3s_version = var.k3s_version == "latest" ? jsondecode(data.http.k3s_latest_release[0].response_body).name : var.k3s_version

  # SSH public key: prefer the string value; fall back to reading the file path.
  # GitHub keys (github_ssh_keys_username) are appended when set.
  ssh_public_key = join("\n", compact(concat(
    [var.public_key != null ? var.public_key : trimspace(file(pathexpand(var.public_key_path)))],
    var.github_ssh_keys_username != "" ? [for k in split("\n", trimspace(data.http.github_ssh_keys[0].response_body)) : k if k != ""] : []
  )))

  # Resolved OS image IDs: explicit variable wins; otherwise auto-detected from tenancy
  os_image_id = var.os_image_id != null ? var.os_image_id : data.oci_core_images.k3s_nodes[0].images[0].id

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
    { name = "Bastion", desired_state = var.enable_bastion ? "ENABLED" : "DISABLED" },
  ]

  # Internal LB IP used as the k3s server URL for agent join
  k3s_internal_lb_ip = oci_load_balancer_load_balancer.k3s_internal_lb.ip_address_details[0].ip_address

  # Public NLB IP (first public address)
  public_lb_ip = [
    for addr in oci_network_load_balancer_network_load_balancer.k3s_public_nlb.ip_addresses :
    addr.ip_address if addr.is_public == true
  ]

  # Grafana hostname: user-supplied or derived from NLB IP via sslip.io.
  # Cloud-init uses this to create the Gateway listener, Certificate, and HTTPRoute
  # so that gitops/ manifests remain IP-independent across redeployments.
  grafana_hostname = var.grafana_hostname != null ? var.grafana_hostname : (
    length(local.public_lb_ip) > 0 ? "grafana.${local.public_lb_ip[0]}.sslip.io" : ""
  )

  # Map of node-tier → NSG ID; used to apply shared ingress rules to both tiers.
  nodes_nsgs = {
    workers = oci_core_network_security_group.workers.id
    servers = oci_core_network_security_group.servers.id
  }

  # Shared cloud-init vars passed to both server and agent template files.
  # Server-specific vars are merged on top in data.tf.
  k3s_common_cloud_init_vars = {
    k3s_version               = local.k3s_version
    k3s_subnet                = var.k3s_subnet
    k3s_token                 = var.enable_vault ? "" : random_password.k3s_token.result
    k3s_url                   = local.k3s_internal_lb_ip
    vault_secret_id_k3s_token = var.enable_vault ? oci_vault_secret.k3s_token[0].id : ""
  }

  # ── kubeconfig hint strings (used by output.tf) ───────────────────────────

  _kubeconfig_hint_bastion = templatefile("${path.module}/files/kubeconfig-hint-bastion.tpl", {
    bastion_id    = var.enable_bastion ? oci_bastion_bastion.k3s[0].id : "<bastion-ocid>"
    server_ip     = try(data.oci_core_instance.k3s_servers[0].private_ip, "<server-ip>")
    public_nlb_ip = try(local.public_lb_ip[0], "<public-nlb-ip>")
    kube_api_port = var.kube_api_port
  })

  _kubeconfig_hint_no_bastion = templatefile("${path.module}/files/kubeconfig-hint-no-bastion.tpl", {
    server_ocid       = try(data.oci_core_instance.k3s_servers[0].id, "<server-ocid>")
    my_public_ip_cidr = var.my_public_ip_cidr
    public_nlb_ip     = try(local.public_lb_ip[0], "<public-nlb-ip>")
    kube_api_port     = var.kube_api_port
  })
}
