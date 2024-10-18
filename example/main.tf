variable "compartment_ocid" { type = string }
variable "tenancy_ocid" { type = string }
variable "user_ocid" { type = string }
variable "fingerprint" { type = string }
variable "private_key_path" { type = string }
variable "region" { type = string }
variable "availability_domain" { type = string }
variable "my_public_ip_cidr" { type = string }
variable "cluster_name" { type = string }
variable "os_image_id" { type = string }
variable "certmanager_email_address" { type = string }

variable "k3s_server_pool_size" {
  type    = number
  default = 3
}
variable "k3s_worker_pool_size" {
  type    = number
  default = 0
}
variable "k3s_extra_worker_node" {
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

module "k3s_cluster" {
  source = "../"

  availability_domain       = var.availability_domain
  tenancy_ocid              = var.tenancy_ocid
  compartment_ocid          = var.compartment_ocid
  my_public_ip_cidr         = var.my_public_ip_cidr
  cluster_name              = var.cluster_name
  environment               = var.environment
  os_image_id               = var.os_image_id
  certmanager_email_address = var.certmanager_email_address
  k3s_server_pool_size      = var.k3s_server_pool_size
  k3s_worker_pool_size      = var.k3s_worker_pool_size
  k3s_extra_worker_node     = var.k3s_extra_worker_node
  expose_kubeapi            = var.expose_kubeapi
  enable_bastion            = var.enable_bastion
  ingress_controller        = "traefik2"
}

output "k3s_servers_private_ips" { value = module.k3s_cluster.k3s_servers_private_ips }
output "k3s_workers_private_ips" { value = module.k3s_cluster.k3s_workers_private_ips }
output "k3s_extra_worker_private_ip" { value = module.k3s_cluster.k3s_extra_worker_private_ip }
output "internal_lb_ip" { value = module.k3s_cluster.internal_lb_ip }
output "public_nlb_ip" { value = module.k3s_cluster.public_nlb_ip }
output "bastion_public_ip" { value = module.k3s_cluster.bastion_public_ip }
output "kubeconfig_hint" { value = module.k3s_cluster.kubeconfig_hint }
