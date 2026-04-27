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
variable "enable_bastion" {
  type    = bool
  default = false
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

module "k3s_cluster" {
  source = "../"

  availability_domain         = var.availability_domain
  tenancy_ocid                = var.tenancy_ocid
  compartment_ocid            = var.compartment_ocid
  region                      = var.region
  my_public_ip_cidr           = var.my_public_ip_cidr
  cluster_name                = var.cluster_name
  environment                 = var.environment
  os_image_id                 = var.os_image_id
  certmanager_email_address   = var.certmanager_email_address
  k3s_server_pool_size        = var.k3s_server_pool_size
  k3s_worker_pool_size        = var.k3s_worker_pool_size
  k3s_standalone_worker       = var.k3s_standalone_worker
  expose_kubeapi              = var.expose_kubeapi
  enable_bastion              = var.enable_bastion
  public_key                  = var.public_key
  public_key_path             = var.public_key_path
  enable_backup               = var.enable_backup
  enable_vault                = var.enable_vault
  enable_object_storage_state = var.enable_object_storage_state
  enable_longhorn_backup      = var.enable_longhorn_backup
  enable_notifications        = var.enable_notifications
  alertmanager_email          = var.alertmanager_email
  enable_mysql                = var.enable_mysql
  mysql_admin_username        = var.mysql_admin_username
  mysql_shape                 = var.mysql_shape
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
