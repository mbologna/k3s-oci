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
  os_image_id = coalesce(var.os_image_id, data.oci_core_images.k3s_nodes[0].images[0].id)

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

  # ── kubeconfig hint strings (used by output.tf) ───────────────────────────

  _kubeconfig_hint_bastion = <<-EOT
    # ── Fetch kubeconfig via OCI Bastion Service ─────────────────────────────
    # Run from the example/ directory (requires oci CLI, tofu, jq, nc, ssh):
    #   ./get-kubeconfig.sh
    #
    # Or manually — port-forwarding session (no Bastion plugin required):
    #   oci bastion session create-port-forwarding \
    #     --bastion-id ${var.enable_bastion ? oci_bastion_bastion.k3s[0].id : "<bastion-ocid>"} \
    #     --ssh-public-key-file ~/.ssh/id_rsa.pub \
    #     --target-private-ip ${try(data.oci_core_instance.k3s_servers[0].private_ip, "<server-ip>")} \
    #     --target-port 22 \
    #     --session-ttl 1800
    #   # Open tunnel (replace SESSION and REGION):
    #   ssh -N -L 22222:${try(data.oci_core_instance.k3s_servers[0].private_ip, "<server-ip>")}:22 \
    #       -p 22 ocid1.bastionsession...@host.bastion.<region>.oci.oraclecloud.com &
    #   # Fetch kubeconfig through tunnel:
    #   ssh -p 22222 ubuntu@localhost "sudo cat /etc/rancher/k3s/k3s.yaml" \
    #     | sed 's|127.0.0.1:6443|${try(local.public_lb_ip[0], "<public-nlb-ip>")}:${var.kube_api_port}|'
  EOT

  _kubeconfig_hint_no_bastion = <<-EOT
    # ── No bastion configured ────────────────────────────────────────────────
    # Nodes are in a private subnet and cannot be reached directly.
    # Pick one option:
    #
    # Option A — OCI serial console (no infra change, one-time):
    #   OCI console connections require an RSA key (ed25519 is not supported).
    #   This one-liner creates the connection and opens the shell immediately:
    #   ssh -o ControlPath=none $(oci compute instance-console-connection create \
    #       --instance-id ${try(data.oci_core_instance.k3s_servers[0].id, "<server-ocid>")} \
    #       --ssh-public-key-file ~/.ssh/id_rsa.pub \
    #       --query 'data."connection-string"' --raw-output)
    #   # Then: sudo cat /etc/rancher/k3s/k3s.yaml
    #
    # Options B & C — both require a tofu apply:
    #
    # Option B — Enable OCI Bastion Service (managed, Always Free, no storage):
    #   Add  enable_bastion = true  to terraform.tfvars, then run tofu apply.
    #   Then re-run: tofu output kubeconfig_hint
    #
    # Option C — Expose kubeapi via public NLB (restricted to ${var.my_public_ip_cidr}):
    #   Add  expose_kubeapi = true  to terraform.tfvars, then run tofu apply.
    #   Use Option A or B once to fetch the kubeconfig, then update the server URL:
    #   sed -i '' 's|127.0.0.1:6443|${try(local.public_lb_ip[0], "<public-nlb-ip>")}:${var.kube_api_port}|' ~/.kube/k3s-oci.yaml
  EOT
}
