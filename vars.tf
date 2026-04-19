# ── OCI Identity ──────────────────────────────────────────────────────────────

variable "tenancy_ocid" {
  type        = string
  description = "OCID of the tenancy"
}

variable "compartment_ocid" {
  type        = string
  description = "OCID of the compartment where all resources are created"
}

variable "region" {
  type        = string
  description = "OCI region (must be your home region for Always Free resources)"
}

variable "availability_domain" {
  type        = string
  description = "Availability domain name, e.g. 'Uocm:EU-FRANKFURT-1-AD-1'"
}

# ── Cluster identity ──────────────────────────────────────────────────────────

variable "cluster_name" {
  type        = string
  description = "Logical name for the cluster. Used in display names and freeform tags."
}

variable "environment" {
  type        = string
  description = "Deployment environment label (e.g. staging, production)"
  default     = "staging"
}

variable "unique_tag_key" {
  type        = string
  description = "Freeform tag key applied to every resource for identification"
  default     = "k3s-provisioner"
}

variable "unique_tag_value" {
  type        = string
  description = "Freeform tag value applied to every resource for identification"
  default     = "https://github.com/mbologna/k3s-oci"
}

# ── SSH ───────────────────────────────────────────────────────────────────────

variable "public_key_path" {
  type        = string
  description = "Path to the SSH public key placed on every instance"
  default     = "~/.ssh/id_rsa.pub"
}

variable "my_public_ip_cidr" {
  type        = string
  description = "Your workstation public IP in CIDR notation (e.g. 1.2.3.4/32). Used to restrict SSH and kubeapi access."

  validation {
    condition     = can(cidrnetmask(var.my_public_ip_cidr))
    error_message = "my_public_ip_cidr must be a valid CIDR block (e.g. 1.2.3.4/32)."
  }
}

# ── Compute ───────────────────────────────────────────────────────────────────

variable "os_image_id" {
  type        = string
  description = "OCID of the OS image (Ubuntu 22.04 or Oracle Linux 9 recommended)"
}

variable "compute_shape" {
  type        = string
  description = "OCI compute shape for k3s nodes"
  default     = "VM.Standard.A1.Flex"
}

variable "server_ocpus" {
  type        = number
  description = "OCPUs per control-plane node. Total OCPUs across all nodes must not exceed 4 (Always Free)."
  default     = 1
}

variable "server_memory_in_gbs" {
  type        = number
  description = "RAM in GB per control-plane node. Total RAM must not exceed 24 GB (Always Free)."
  default     = 6
}

variable "worker_ocpus" {
  type        = number
  description = "OCPUs per worker node."
  default     = 1
}

variable "worker_memory_in_gbs" {
  type        = number
  description = "RAM in GB per worker node."
  default     = 6
}

variable "boot_volume_size_in_gbs" {
  type        = number
  description = "Boot volume size in GB. Max 50 GB per instance to stay within the 200 GB Always Free block storage budget."
  default     = 50

  validation {
    condition     = var.boot_volume_size_in_gbs >= 47 && var.boot_volume_size_in_gbs <= 200
    error_message = "boot_volume_size_in_gbs must be between 47 and 200."
  }
}

variable "fault_domains" {
  type        = list(string)
  description = "Fault domains to spread the instance pool across"
  default     = ["FAULT-DOMAIN-1", "FAULT-DOMAIN-2", "FAULT-DOMAIN-3"]
}

# ── Cluster topology ──────────────────────────────────────────────────────────

variable "k3s_server_pool_size" {
  type        = number
  description = "Number of k3s control-plane nodes in the instance pool. Use 3 for HA (etcd quorum). Must be an odd number >= 1."
  default     = 3

  validation {
    condition     = var.k3s_server_pool_size >= 1 && var.k3s_server_pool_size % 2 == 1
    error_message = "k3s_server_pool_size must be a positive odd number (1, 3, 5 …) for etcd quorum."
  }
}

variable "k3s_worker_pool_size" {
  type        = number
  description = "Number of k3s worker nodes managed by an instance pool (can be 0)."
  default     = 0
}

variable "k3s_extra_worker_node" {
  type        = bool
  description = <<-EOT
    When true, provisions one additional standalone worker instance (oci_core_instance).
    This is the recommended way to use the 4th Always Free A1.Flex OCPU without exceeding
    OCI instance pool limits per tenancy. Default topology: 3 servers (pool) + 1 extra worker.
  EOT
  default     = true
}

# ── Bastion ───────────────────────────────────────────────────────────────────

variable "enable_bastion" {
  type        = bool
  description = <<-EOT
    Provision a bastion host using the VM.Standard.E2.1.Micro shape (Always Free, AMD).
    When enabled, k3s nodes are placed in a private subnet and the bastion is the only
    SSH entry point. Strongly recommended for production.
  EOT
  default     = false
}

variable "bastion_shape" {
  type        = string
  description = "Shape for the bastion instance. VM.Standard.E2.1.Micro is Always Free."
  default     = "VM.Standard.E2.1.Micro"
}

# ── k3s ───────────────────────────────────────────────────────────────────────

variable "k3s_version" {
  type        = string
  description = "k3s version to install. 'latest' resolves the current stable release at plan time via the GitHub API."
  default     = "latest"
}

variable "k3s_subnet" {
  type        = string
  description = "Subnet name used to derive the flannel interface. Leave 'default_route_table' to let k3s auto-detect."
  default     = "default_route_table"
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "oci_core_vcn_cidr" {
  type        = string
  description = "CIDR block for the VCN"
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type        = string
  description = "CIDR for the public subnet (load balancers and optional bastion)"
  default     = "10.0.0.0/24"
}

variable "private_subnet_cidr" {
  type        = string
  description = "CIDR for the private subnet (k3s nodes)"
  default     = "10.0.1.0/24"
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

# ── Load balancers ────────────────────────────────────────────────────────────

variable "public_lb_shape" {
  type        = string
  description = "Shape for the public NLB"
  default     = "flexible"
}

variable "kube_api_port" {
  type        = number
  description = "Port the k3s API server listens on"
  default     = 6443
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
  type        = number
  description = "NodePort on workers that the ingress controller binds for HTTP traffic"
  default     = 30080
}

variable "ingress_controller_https_nodeport" {
  type        = number
  description = "NodePort on workers that the ingress controller binds for HTTPS traffic"
  default     = 30443
}

variable "expose_kubeapi" {
  type        = bool
  description = "Expose the Kubernetes API server via the public NLB (restricted to my_public_ip_cidr)"
  default     = false
}

# ── IAM ───────────────────────────────────────────────────────────────────────

variable "oci_identity_dynamic_group_name" {
  type        = string
  description = "Name for the OCI dynamic group granting instances access to the OCI API"
  default     = "k3s-cluster-dynamic-group"
}

variable "oci_identity_policy_name" {
  type        = string
  description = "Name for the OCI IAM policy attached to the dynamic group"
  default     = "k3s-cluster-policy"
}

# ── Ingress ───────────────────────────────────────────────────────────────────

variable "disable_ingress" {
  type        = bool
  description = "When true, no ingress controller is installed (disables Traefik and skips additional controllers)"
  default     = false
}

variable "ingress_controller" {
  type        = string
  description = "Ingress controller to deploy. 'traefik' keeps the k3s built-in, 'nginx' and 'istio' replace it."
  default     = "traefik"

  validation {
    condition     = contains(["traefik", "nginx", "traefik2", "istio"], var.ingress_controller)
    error_message = "Supported values: traefik, traefik2, nginx, istio."
  }
}

variable "nginx_ingress_release" {
  type    = string
  default = "v1.12.1"
}

variable "istio_release" {
  type    = string
  default = "1.21.2"
}

# ── cert-manager ──────────────────────────────────────────────────────────────

variable "install_certmanager" {
  type    = bool
  default = true
}

variable "certmanager_release" {
  type    = string
  default = "v1.16.3"
}

variable "certmanager_email_address" {
  type        = string
  description = "Email address for Let's Encrypt ACME registration. Must be a real address."

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.certmanager_email_address)) && var.certmanager_email_address != "changeme@example.com"
    error_message = "certmanager_email_address must be a valid email address (not the placeholder)."
  }
}

# ── Longhorn ──────────────────────────────────────────────────────────────────

variable "install_longhorn" {
  type    = bool
  default = true
}

variable "longhorn_release" {
  type    = string
  default = "v1.8.1"
}

# ── ArgoCD ────────────────────────────────────────────────────────────────────

variable "install_argocd" {
  type    = bool
  default = true
}

variable "argocd_release" {
  type    = string
  default = "v2.14.9"
}

variable "install_argocd_image_updater" {
  type    = bool
  default = true
}

variable "argocd_image_updater_release" {
  type    = string
  default = "v0.16.0"
}

# ── kured ─────────────────────────────────────────────────────────────────────

variable "install_kured" {
  type        = bool
  description = "Install kured for automatic node reboots after unattended-upgrades"
  default     = true
}

variable "kured_release" {
  type        = string
  description = "kured Helm chart version"
  default     = "5.5.1"
}
