terraform {
  required_version = ">= 1.9"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 9.15.0, < 10.0.0"
    }
  }
}

provider "oci" {
  region = var.region
}

module "k3s_oci" {
  source = "../"

  tenancy_ocid        = var.tenancy_ocid
  compartment_ocid    = var.compartment_ocid
  availability_domain = var.availability_domain
  cluster_name        = var.cluster_name
  os_family           = var.os_family
  image_id            = var.image_id
  ssh_public_key      = var.ssh_public_key
  certmanager_email   = var.certmanager_email
  gitops_repo_url     = var.gitops_repo_url
  alert_email         = var.alert_email
  uptime_urls         = var.uptime_urls
}

variable "region" {
  type        = string
  description = "OCI region (the tenancy's home region: Always Free resources live there)."
}

variable "tenancy_ocid" {
  type        = string
  description = "Tenancy OCID."
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment OCID (the tenancy OCID works)."
}

variable "availability_domain" {
  type        = string
  description = "Availability domain, e.g. \"RyPa:PHX-AD-1\"."
}

variable "cluster_name" {
  type        = string
  description = "Cluster name."
  default     = "k3s-oci"
}

variable "os_family" {
  type        = string
  description = "opensuse, fcos or flatcar (scripts/deploy.sh needs the same OS_FAMILY)."
  default     = "opensuse"
}

variable "image_id" {
  type        = string
  description = "Custom image OCID (scripts/import-image.sh). null only for plans."
  default     = null
}

variable "ssh_public_key" {
  type        = string
  description = "SSH key for break-glass access (scripts/tunnel.sh ssh)."
  default     = null
}

variable "certmanager_email" {
  type        = string
  description = "Let's Encrypt email (creates the ClusterIssuers)."
  default     = null
}

variable "gitops_repo_url" {
  type        = string
  description = "Your fork of this repository (gitops/update-repo-url.sh)."
  default     = "https://github.com/mbologna/k3s-oci.git"
}

variable "alert_email" {
  type        = string
  description = "Email for OCI Monitoring alarms (null disables them)."
  default     = null
}

variable "uptime_urls" {
  type        = list(string)
  description = "One HTTPS URL for the APM synthetic uptime check."
  default     = []
}

output "cluster_name" {
  value = module.k3s_oci.cluster_name
}

output "os_family" {
  value = module.k3s_oci.os_family
}

output "kubeconfig" {
  value     = module.k3s_oci.kubeconfig
  sensitive = true
}

output "node_private_ips" {
  value = module.k3s_oci.node_private_ips
}

output "node_instance_ids" {
  value = module.k3s_oci.node_instance_ids
}

output "internal_lb_ip" {
  value = module.k3s_oci.internal_lb_ip
}

output "public_nlb_ip" {
  value = module.k3s_oci.public_nlb_ip
}

output "bastion_id" {
  value = module.k3s_oci.bastion_id
}

output "backup_bucket" {
  value = module.k3s_oci.backup_bucket
}

output "s3_endpoint" {
  value = module.k3s_oci.s3_endpoint
}
