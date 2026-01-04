# ── OCI Identity ──────────────────────────────────────────────────────────────

variable "tenancy_ocid" {
  type        = string
  description = "OCID of the tenancy"
}

variable "compartment_ocid" {
  type        = string
  description = "OCID of the compartment where all resources are created"
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
  description = "Path to SSH public key file. Used as fallback when public_key is null."
  default     = "~/.ssh/id_rsa.pub"
}

variable "public_key" {
  type        = string
  description = <<-EOT
    SSH public key content placed on every instance. Preferred over public_key_path —
    pass the key string directly for CI pipelines where ~/.ssh does not exist.
    When null, the key is read from public_key_path at plan time.
  EOT
  default     = null
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
  description = "OCID of the Ubuntu 24.04 LTS (Noble) image for A1.Flex and E2.1.Micro instances. Find OCIDs at https://docs.oracle.com/en-us/iaas/images/"
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
  description = "When true, no ingress controller is installed (disables Traefik and skips Traefik 2 install)"
  default     = false
}

variable "ingress_controller" {
  type        = string
  description = "'traefik' keeps the k3s built-in Traefik v2; 'traefik2' installs Traefik via Helm for finer control."
  default     = "traefik"

  validation {
    condition     = contains(["traefik", "traefik2"], var.ingress_controller)
    error_message = "Supported values: traefik (k3s built-in), traefik2 (Helm-managed)."
  }
}

# ── cert-manager (always installed — keeps cluster active, avoids idle reclamation) ───

variable "certmanager_release" {
  type        = string
  description = "cert-manager release to install."
  # renovate: datasource=github-releases depName=cert-manager/cert-manager
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

# ── Longhorn (always installed — provides distributed storage + cluster activity) ──

variable "longhorn_release" {
  type        = string
  description = "Longhorn release to install."
  # renovate: datasource=github-releases depName=longhorn/longhorn
  default = "v1.8.1"
}

# ── ArgoCD (always installed — GitOps controller keeps cluster active) ────────

variable "argocd_chart_release" {
  type        = string
  description = "ArgoCD Helm chart version (argo/argo-cd). Chart version maps 1:1 to an ArgoCD app version."
  # renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm
  default = "7.8.23"
}

variable "argocd_image_updater_release" {
  type        = string
  description = "ArgoCD Image Updater release to install (kubectl apply)."
  # renovate: datasource=github-releases depName=argoproj-labs/argocd-image-updater
  default = "v0.16.0"
}

variable "argocd_hostname" {
  type        = string
  description = "Fully-qualified hostname for the ArgoCD UI IngressRoute (e.g. argocd.example.com). When set, a Traefik IngressRoute with a cert-manager TLS certificate is created."
  default     = null
}

variable "longhorn_hostname" {
  type        = string
  description = "Fully-qualified hostname for the Longhorn UI IngressRoute (e.g. longhorn.example.com). When set, a Traefik IngressRoute with basic-auth and a cert-manager TLS certificate is created."
  default     = null
}

variable "gitops_repo_url" {
  type        = string
  description = "Git repository URL for the ArgoCD App of Apps (e.g. https://github.com/your-org/k3s-oci.git). Set this to your fork so ArgoCD pulls from the right repo."
  default     = "https://github.com/mbologna/k3s-oci.git"
}

# ── kured (always installed — graceful kernel reboot management) ──────────────

variable "kured_release" {
  type        = string
  description = "kured Helm chart version."
  # renovate: datasource=helm depName=kured registryUrl=https://kubereboot.github.io/charts
  default = "5.5.1"
}

variable "kured_reboot_days" {
  type        = list(string)
  description = "Days of the week on which kured may reboot nodes. Defaults to all days."
  default     = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
}

variable "kured_start_time" {
  type        = string
  description = "Start of the kured maintenance window (UTC, HH:MM). Default 22:00 UTC = midnight CET / 01:00 CEST."
  default     = "22:00"
}

variable "kured_end_time" {
  type        = string
  description = "End of the kured maintenance window (UTC, HH:MM). Default 06:00 UTC = 08:00 CET / 09:00 CEST."
  default     = "06:00"
}

# ── OCI CLI ───────────────────────────────────────────────────────────────────

variable "oci_cli_version" {
  type        = string
  description = "OCI CLI version installed on control-plane nodes for first-server detection."
  # renovate: datasource=github-releases depName=oracle/oci-cli
  default = "3.52.0"
}
