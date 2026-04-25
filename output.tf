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

output "terraform_state_backend" {
  description = "S3-compatible backend config snippet for storing Terraform state in the provisioned OCI Object Storage bucket. Replace <region> and add S3 credentials (OCI Customer Secret Key)."
  value = var.enable_object_storage_state ? {
    bucket    = oci_objectstorage_bucket.terraform_state[0].name
    namespace = data.oci_objectstorage_namespace.k3s[0].namespace
    hint      = "Add to your backend block: endpoint = https://${data.oci_objectstorage_namespace.k3s[0].namespace}.compat.objectstorage.<region>.oraclecloud.com"
  } : null
}

output "longhorn_backup_setup" {
  description = "Instructions to connect Longhorn to the OCI Object Storage backup bucket. Null if enable_longhorn_backup = false."
  value = var.enable_longhorn_backup ? {
    bucket    = oci_objectstorage_bucket.longhorn_backup[0].name
    namespace = data.oci_objectstorage_namespace.k3s[0].namespace
    step_1    = "Create OCI Customer Secret Key: Console → Identity → Users → <user> → Customer Secret Keys → Generate"
    step_2    = "kubectl create secret generic longhorn-backup-secret --from-literal=AWS_ACCESS_KEY_ID='<key-id>' --from-literal=AWS_SECRET_ACCESS_KEY='<secret>' -n longhorn-system"
    step_3    = "Uncomment and fill gitops/longhorn/backup-target.yaml with bucket '${oci_objectstorage_bucket.longhorn_backup[0].name}', namespace '${data.oci_objectstorage_namespace.k3s[0].namespace}'"
  } : null
}

output "notification_topic_endpoint" {
  description = "OCI Notifications HTTPS endpoint for the Alertmanager webhook receiver (null if enable_notifications = false)."
  value       = var.enable_notifications ? oci_ons_notification_topic.k3s_alerts[0].api_endpoint : null
  sensitive   = true
}

output "mysql_endpoint" {
  description = "MySQL HeatWave connection endpoint (hostname:port). Null if enable_mysql = false."
  value       = var.enable_mysql && length(oci_mysql_mysql_db_system.k3s) > 0 ? "${oci_mysql_mysql_db_system.k3s[0].endpoints[0].hostname}:${oci_mysql_mysql_db_system.k3s[0].endpoints[0].port}" : null
}

output "mysql_admin_credentials" {
  description = "MySQL HeatWave admin credentials (sensitive). Null if enable_mysql = false."
  value = var.enable_mysql ? {
    username = var.mysql_admin_username
    password = random_password.mysql_admin_password[0].result
    endpoint = var.enable_mysql && length(oci_mysql_mysql_db_system.k3s) > 0 ? "${oci_mysql_mysql_db_system.k3s[0].endpoints[0].hostname}:${oci_mysql_mysql_db_system.k3s[0].endpoints[0].port}" : null
  } : null
  sensitive = true
}

output "vault_id" {
  description = "OCI Vault OCID (null if enable_vault = false)"
  value       = var.enable_vault ? oci_kms_vault.k3s[0].id : null
}
