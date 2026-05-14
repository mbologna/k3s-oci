variable "compartment_ocid" { type = string }
variable "tenancy_ocid" { type = string }
variable "region" { type = string }
variable "availability_domain" { type = string }
variable "my_public_ip_cidr" { type = string }
variable "cluster_name" { type = string }
variable "os_image_id" {
  type    = string
  default = null
}
variable "certmanager_email_address" { type = string }

# Optional explicit API key auth — when null, the OCI provider reads from ~/.oci/config.
# Run `oci setup config` to populate ~/.oci/config and leave these commented out.
variable "user_ocid" {
  type    = string
  default = null
}
variable "fingerprint" {
  type    = string
  default = null
}
variable "private_key_path" {
  type    = string
  default = null
}

variable "k3s_server_pool_size" {
  type    = number
  default = 3
}
variable "k3s_worker_pool_size" {
  type    = number
  default = 0
}
variable "k3s_standalone_worker" {
  type    = bool
  default = true
}
variable "expose_kubeapi" {
  type    = bool
  default = false
}
variable "expose_ssh" {
  type    = bool
  default = false
}
variable "enable_bastion" {
  type    = bool
  default = true
}
variable "environment" {
  type    = string
  default = "staging"
}

variable "public_key" {
  type    = string
  default = null
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

# ── Optional Always Free features ─────────────────────────────────────────────

variable "enable_backup" {
  type    = bool
  default = true
}

variable "enable_vault" {
  type    = bool
  default = true
}

variable "enable_object_storage_state" {
  type    = bool
  default = true
}

variable "enable_longhorn_backup" {
  type    = bool
  default = true
}

variable "enable_notifications" {
  type    = bool
  default = false
}

variable "alertmanager_email" {
  type    = string
  default = null
}

variable "enable_mysql" {
  type    = bool
  default = false
}

variable "mysql_admin_username" {
  type    = string
  default = "admin"
}

variable "mysql_shape" {
  type    = string
  default = "MySQL.Free"
}

variable "github_ssh_keys_username" {
  type    = string
  default = ""
}

variable "longhorn_hostname" {
  type    = string
  default = null
}

variable "grafana_hostname" {
  type    = string
  default = null
}

variable "gitops_repo_url" {
  type    = string
  default = "https://github.com/mbologna/k3s-oci.git"
}

# ── External DNS (Cloudflare) ─────────────────────────────────────────────────

variable "enable_external_dns" {
  type    = bool
  default = false
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
  default   = null
}

variable "cloudflare_zone_id" {
  type    = string
  default = null
}

variable "external_dns_domain_filter" {
  type    = string
  default = null
}

# ── External Secrets Operator (OCI Vault) ─────────────────────────────────────

variable "enable_external_secrets" {
  type    = bool
  default = false
}

# ── DNS-01 ACME challenge (Cloudflare) ────────────────────────────────────────

variable "enable_dns01_challenge" {
  type    = bool
  default = false
}

# ── Compute & sizing ──────────────────────────────────────────────────────────

variable "compute_shape" {
  type    = string
  default = "VM.Standard.A1.Flex"
}

variable "server_ocpus" {
  type    = number
  default = 1
}

variable "server_memory_in_gbs" {
  type    = number
  default = 6
}

variable "worker_ocpus" {
  type    = number
  default = 1
}

variable "worker_memory_in_gbs" {
  type    = number
  default = 6
}

variable "boot_volume_size_in_gbs" {
  type    = number
  default = 50
}

variable "fault_domains" {
  type    = list(string)
  default = ["FAULT-DOMAIN-1", "FAULT-DOMAIN-2", "FAULT-DOMAIN-3"]
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "oci_core_vcn_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.0.0/24"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "oci_core_vcn_dns_label" {
  type    = string
  default = "k3svcn"
}

variable "public_subnet_dns_label" {
  type    = string
  default = "k3spublic"
}

variable "private_subnet_dns_label" {
  type    = string
  default = "k3sprivate"
}

variable "kube_api_port" {
  type    = number
  default = 6443
}

variable "http_lb_port" {
  type    = number
  default = 80
}

variable "https_lb_port" {
  type    = number
  default = 443
}

variable "ingress_controller_http_nodeport" {
  type    = number
  default = 30080
}

variable "ingress_controller_https_nodeport" {
  type    = number
  default = 30443
}

variable "k3s_subnet" {
  type    = string
  default = "default_route_table"
}

# ── k3s ───────────────────────────────────────────────────────────────────────

variable "k3s_version" {
  type    = string
  default = "latest"
}

# ── IAM ───────────────────────────────────────────────────────────────────────

variable "unique_tag_key" {
  type    = string
  default = "k3s-provisioner"
}

variable "unique_tag_value" {
  type    = string
  default = "https://github.com/mbologna/k3s-oci"
}

variable "oci_identity_dynamic_group_name" {
  type    = string
  default = "k3s-cluster-dynamic-group"
}

variable "oci_identity_policy_name" {
  type    = string
  default = "k3s-cluster-policy"
}

# ── App config ────────────────────────────────────────────────────────────────

variable "longhorn_ui_username" {
  type    = string
  default = "admin"
}

variable "dockerhub_username" {
  type    = string
  default = ""
}

variable "dockerhub_password" {
  type      = string
  sensitive = true
  default   = ""
}

# ── Chart versions ────────────────────────────────────────────────────────────

variable "gateway_api_version" {
  type    = string
  default = "v1.5.1"
}

variable "certmanager_chart_version" {
  type    = string
  default = "v1.20.2"
}

variable "argocd_chart_version" {
  type    = string
  default = "9.5.9"
}

variable "external_secrets_chart_version" {
  type    = string
  default = "2.4.1"
}

module "k3s_cluster" {
  source = "../"

  availability_domain               = var.availability_domain
  tenancy_ocid                      = var.tenancy_ocid
  compartment_ocid                  = var.compartment_ocid
  region                            = var.region
  my_public_ip_cidr                 = var.my_public_ip_cidr
  cluster_name                      = var.cluster_name
  environment                       = var.environment
  os_image_id                       = var.os_image_id
  certmanager_email_address         = var.certmanager_email_address
  k3s_server_pool_size              = var.k3s_server_pool_size
  k3s_worker_pool_size              = var.k3s_worker_pool_size
  k3s_standalone_worker             = var.k3s_standalone_worker
  expose_kubeapi                    = var.expose_kubeapi
  expose_ssh                        = var.expose_ssh
  enable_bastion                    = var.enable_bastion
  public_key                        = var.public_key
  public_key_path                   = var.public_key_path
  enable_backup                     = var.enable_backup
  enable_vault                      = var.enable_vault
  enable_object_storage_state       = var.enable_object_storage_state
  enable_longhorn_backup            = var.enable_longhorn_backup
  enable_notifications              = var.enable_notifications
  alertmanager_email                = var.alertmanager_email
  enable_mysql                      = var.enable_mysql
  mysql_admin_username              = var.mysql_admin_username
  mysql_shape                       = var.mysql_shape
  github_ssh_keys_username          = var.github_ssh_keys_username
  longhorn_hostname                 = var.longhorn_hostname
  grafana_hostname                  = var.grafana_hostname
  gitops_repo_url                   = var.gitops_repo_url
  enable_external_dns               = var.enable_external_dns
  cloudflare_api_token              = var.cloudflare_api_token
  cloudflare_zone_id                = var.cloudflare_zone_id
  external_dns_domain_filter        = var.external_dns_domain_filter
  enable_external_secrets           = var.enable_external_secrets
  enable_dns01_challenge            = var.enable_dns01_challenge
  compute_shape                     = var.compute_shape
  server_ocpus                      = var.server_ocpus
  server_memory_in_gbs              = var.server_memory_in_gbs
  worker_ocpus                      = var.worker_ocpus
  worker_memory_in_gbs              = var.worker_memory_in_gbs
  boot_volume_size_in_gbs           = var.boot_volume_size_in_gbs
  fault_domains                     = var.fault_domains
  oci_core_vcn_cidr                 = var.oci_core_vcn_cidr
  public_subnet_cidr                = var.public_subnet_cidr
  private_subnet_cidr               = var.private_subnet_cidr
  oci_core_vcn_dns_label            = var.oci_core_vcn_dns_label
  public_subnet_dns_label           = var.public_subnet_dns_label
  private_subnet_dns_label          = var.private_subnet_dns_label
  kube_api_port                     = var.kube_api_port
  http_lb_port                      = var.http_lb_port
  https_lb_port                     = var.https_lb_port
  ingress_controller_http_nodeport  = var.ingress_controller_http_nodeport
  ingress_controller_https_nodeport = var.ingress_controller_https_nodeport
  k3s_subnet                        = var.k3s_subnet
  k3s_version                       = var.k3s_version
  unique_tag_key                    = var.unique_tag_key
  unique_tag_value                  = var.unique_tag_value
  oci_identity_dynamic_group_name   = var.oci_identity_dynamic_group_name
  oci_identity_policy_name          = var.oci_identity_policy_name
  longhorn_ui_username              = var.longhorn_ui_username
  dockerhub_username                = var.dockerhub_username
  dockerhub_password                = var.dockerhub_password
  gateway_api_version               = var.gateway_api_version
  certmanager_chart_version         = var.certmanager_chart_version
  argocd_chart_version              = var.argocd_chart_version
  external_secrets_chart_version    = var.external_secrets_chart_version
}

output "k3s_servers_private_ips" { value = module.k3s_cluster.k3s_servers_private_ips }
output "k3s_workers_private_ips" { value = module.k3s_cluster.k3s_workers_private_ips }
output "k3s_standalone_worker_private_ip" { value = module.k3s_cluster.k3s_standalone_worker_private_ip }
output "internal_lb_ip" { value = module.k3s_cluster.internal_lb_ip }
output "public_nlb_ip" { value = module.k3s_cluster.public_nlb_ip }
output "bastion_ocid" { value = module.k3s_cluster.bastion_ocid }
output "kubeconfig_hint" { value = module.k3s_cluster.kubeconfig_hint }
output "argocd_initial_password_hint" { value = module.k3s_cluster.argocd_initial_password_hint }
output "terraform_state_backend" { value = module.k3s_cluster.terraform_state_backend }
output "longhorn_backup_setup" { value = module.k3s_cluster.longhorn_backup_setup }
output "mysql_endpoint" { value = module.k3s_cluster.mysql_endpoint }
output "vault_id" { value = module.k3s_cluster.vault_id }

output "grafana_admin_credentials" {
  value     = module.k3s_cluster.grafana_admin_credentials
  sensitive = true
}
output "longhorn_ui_credentials" {
  value     = module.k3s_cluster.longhorn_ui_credentials
  sensitive = true
}
output "k3s_token" {
  value     = module.k3s_cluster.k3s_token
  sensitive = true
}
output "notification_topic_endpoint" {
  value     = module.k3s_cluster.notification_topic_endpoint
  sensitive = true
}
output "mysql_admin_credentials" {
  value     = module.k3s_cluster.mysql_admin_credentials
  sensitive = true
}
