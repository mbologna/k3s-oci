output "cluster_name" {
  description = "Cluster name."
  value       = var.cluster_name
}

output "os_family" {
  description = "OS of the nodes (scripts/import-image.sh imports its image)."
  value       = var.os_family
}

output "node_private_ips" {
  description = "Fixed private IP of each node."
  value       = local.node_ips
}

output "node_instance_ids" {
  description = "Instance OCID of each node."
  value       = { for name, inst in oci_core_instance.node : name => inst.id }
}

output "first_node" {
  description = "The node that installs Argo CD (and starts an etcd cluster); scripts/deploy.sh fetches the kubeconfig from it."
  value       = local.first_node
}

output "internal_lb_ip" {
  description = "Private IP of the internal load balancer (Kubernetes API 6443)."
  value       = local.lb_ip
}

output "public_nlb_ip" {
  description = "Public IP of the network load balancer (HTTP/HTTPS ingress). Point DNS here."
  value       = [for ip in oci_network_load_balancer_network_load_balancer.public.ip_addresses : ip.ip_address if ip.is_public][0]
}

output "bastion_id" {
  description = "OCID of the OCI Bastion (null when enable_bastion = false)."
  value       = one(oci_bastion_bastion.this[*].id)
}

output "kubeconfig" {
  description = "Admin kubeconfig (server https://127.0.0.1:6443: the local end of scripts/tunnel.sh)."
  value       = local.kubeconfig
  sensitive   = true
}

output "k3s_token" {
  description = "k3s cluster token (joins, and decrypts the datastore's Secrets on a restore)."
  value       = random_password.k3s_token.result
  sensitive   = true
}

output "mysql_endpoint" {
  description = "MySQL HeatWave address (datastore = \"mysql\"); user k3s, database k3s."
  value       = var.datastore == "mysql" ? "${oci_mysql_mysql_db_system.k3s[0].ip_address}:3306" : null
}

output "mysql_password" {
  description = "Password of the k3s MySQL user (datastore = \"mysql\")."
  value       = var.datastore == "mysql" ? random_password.mysql_admin[0].result : null
  sensitive   = true
}

output "backup_bucket" {
  description = "Object Storage bucket for etcd snapshots (etcd/) and Longhorn backups (longhorn/)."
  value       = oci_objectstorage_bucket.backups.name
}

output "objectstorage_namespace" {
  description = "Object Storage namespace (the S3 endpoint is https://<namespace>.compat.objectstorage.<region>.oraclecloud.com)."
  value       = data.oci_objectstorage_namespace.this.namespace
}

output "s3_endpoint" {
  description = "OCI's S3-compatible endpoint for the backups bucket (Longhorn's BackupTarget, etcd snapshots)."
  value       = "https://${local.s3_endpoint}"
}
