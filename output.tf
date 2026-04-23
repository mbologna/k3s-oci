output "grafana_admin_credentials" {
  description = "Grafana admin credentials (only available after cluster bootstrap)"
  value = {
    username = "admin"
    password = random_password.grafana_admin_password.result
    hint     = "Access via: https://${var.grafana_hostname != null ? var.grafana_hostname : "<grafana-hostname>"}"
  }
  sensitive = true
}

output "argocd_initial_password_hint" {
  description = "Command to retrieve the ArgoCD initial admin password (run after cluster is up)"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
}

output "longhorn_ui_credentials" {
  description = "Longhorn UI credentials (only set when longhorn_hostname is configured)"
  value = var.longhorn_hostname != null ? {
    username = var.longhorn_ui_username
    password = random_password.longhorn_ui_password.result
    url      = "https://${var.longhorn_hostname}"
  } : null
  sensitive = true
}

output "k3s_servers_private_ips" {
  description = "Private IPs of k3s control-plane nodes"
  value       = data.oci_core_instance.k3s_servers[*].private_ip
}

output "k3s_workers_private_ips" {
  description = "Private IPs of k3s worker nodes (instance pool)"
  value       = data.oci_core_instance.k3s_workers[*].private_ip
}

output "k3s_standalone_worker_private_ip" {
  description = "Private IP of the standalone worker node (oci_core_instance, not pool-managed)"
  value       = var.k3s_standalone_worker ? oci_core_instance.k3s_standalone_worker[0].private_ip : null
}

output "internal_lb_ip" {
  description = "Private IP of the internal load balancer (used by agents to join the cluster)"
  value       = local.k3s_internal_lb_ip
}

output "public_nlb_ip" {
  description = "Public IP address of the NLB (point your DNS here)"
  value       = local.public_lb_ip
}

output "bastion_ocid" {
  description = "OCID of the OCI Bastion Service resource (null if enable_bastion = false). Use with example/get-kubeconfig.sh or oci bastion session create-managed-ssh."
  value       = var.enable_bastion ? oci_bastion_bastion.k3s[0].id : null
}

output "k3s_token" {
  description = "k3s cluster join token (sensitive)"
  value       = random_password.k3s_token.result
  sensitive   = true
}

output "kubeconfig_hint" {
  description = "How to retrieve kubeconfig after cluster is up"
  value       = var.enable_bastion ? local._kubeconfig_hint_bastion : local._kubeconfig_hint_no_bastion
}
