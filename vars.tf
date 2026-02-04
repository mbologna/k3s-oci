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

  validation {
    condition     = can(regex("^[^:]+:[A-Z0-9]+-AD-[1-3]$", var.availability_domain))
    error_message = "availability_domain must match the pattern 'Namespace:REGION-AD-N' (e.g. 'Uocm:EU-FRANKFURT-1-AD-1')."
  }
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
  description = <<-EOT
    Your workstation public IP in CIDR notation (e.g. 1.2.3.4/32).
    Restricts OCI Bastion Service session creation (enable_bastion = true) and
    kubeapi access via the public NLB (expose_kubeapi = true).
    k3s nodes are in a private subnet and are only reachable via OCI Bastion sessions.
  EOT

  validation {
    condition     = can(cidrnetmask(var.my_public_ip_cidr))
    error_message = "my_public_ip_cidr must be a valid CIDR block (e.g. 1.2.3.4/32)."
  }
}

# ── Compute ───────────────────────────────────────────────────────────────────

variable "os_image_id" {
  type        = string
  description = "OCID of the Ubuntu 24.04 LTS (Noble) aarch64 image for A1.Flex nodes. If null, the latest matching image is resolved automatically from the tenancy. Find OCIDs at https://docs.oracle.com/en-us/iaas/images/"
  default     = null

  validation {
    condition     = var.os_image_id == null || startswith(var.os_image_id, "ocid1.image.")
    error_message = "os_image_id must be a valid OCI image OCID starting with 'ocid1.image.' or null."
  }
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
  description = "Boot volume size in GB for k3s nodes (servers + workers). OCI minimum is 50 GB for all shapes. With 4 k3s nodes at 50 GB each the total is 200 GB (exactly at the Always Free limit). The bastion uses OCI Bastion Service — no VM, no boot volume."
  default     = 50

  validation {
    condition     = var.boot_volume_size_in_gbs == 50
    error_message = "boot_volume_size_in_gbs must be 50 GB — OCI minimum for all shapes, and 4 × 50 GB = 200 GB exactly fills the Always Free storage limit."
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
  description = <<-EOT
    Number of k3s worker nodes managed by the OCI Instance Pool.
    Set to 0 (default) when using k3s_standalone_worker = true, which is the recommended
    Always Free topology. The pool is kept to allow future scaling beyond the free tier.
  EOT
  default     = 0
}

variable "k3s_standalone_worker" {
  type        = bool
  description = <<-EOT
    When true (default), provisions one worker node as a plain oci_core_instance resource.
    This is the recommended approach for OCI Always Free tenancies: instance pools route
    requests through OCI Capacity Management which can fail for A1.Flex shapes, whereas
    a direct oci_core_instance reliably claims the free allocation.
    Default topology: 3 control-plane nodes (pool) + 1 standalone worker = 4 OCPUs / 24 GB.
  EOT
  default     = true
}

# ── Bastion ───────────────────────────────────────────────────────────────────

variable "enable_bastion" {
  type        = bool
  description = <<-EOT
    Provision an OCI Bastion Service resource (managed SSH proxy, Always Free, no storage).
    When enabled, a STANDARD bastion is created and associated with the private subnet.
    Use example/get-kubeconfig.sh to retrieve kubeconfig via a Bastion session.
    Strongly recommended; without it, nodes are reachable only via serial console.
  EOT
  default     = false
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
  description = "'traefik2' installs Traefik via Helm for full control over the release and values."
  default     = "traefik2"

  validation {
    condition     = var.ingress_controller == "traefik2"
    error_message = "Only 'traefik2' (Helm-managed) is supported. The k3s built-in Traefik option has been removed."
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
  description = "Fully-qualified hostname for the Longhorn UI IngressRoute (e.g. longhorn.example.com). When set, a Traefik IngressRoute with BasicAuth and a cert-manager TLS certificate is created."
  default     = null
}

variable "longhorn_ui_username" {
  type        = string
  description = "Username for Longhorn UI BasicAuth (only used when longhorn_hostname is set)."
  default     = "admin"
}

variable "grafana_hostname" {
  type        = string
  description = "Fully-qualified hostname for the Grafana UI IngressRoute (e.g. grafana.example.com). When set, a Traefik IngressRoute with a cert-manager TLS certificate is created in gitops/monitoring/."
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

# ── k3s automated upgrades (system-upgrade-controller) ───────────────────────

variable "system_upgrade_controller_release" {
  type        = string
  description = "system-upgrade-controller version for k3s automated upgrades."
  # renovate: datasource=github-releases depName=rancher/system-upgrade-controller
  default = "v0.15.2"
}

variable "k3s_upgrade_channel" {
  type        = string
  description = "k3s release channel to track for automated upgrades. 'stable' is recommended; 'latest' tracks RC releases."
  default     = "stable"
  validation {
    condition     = contains(["stable", "latest", "testing"], var.k3s_upgrade_channel)
    error_message = "k3s_upgrade_channel must be one of: stable, latest, testing."
  }
}

# ── OCI CLI ───────────────────────────────────────────────────────────────────

variable "oci_cli_version" {
  type        = string
  description = "OCI CLI version installed on control-plane nodes for first-server detection."
  # renovate: datasource=github-releases depName=oracle/oci-cli
  default = "3.52.0"
}

# ── Backup ────────────────────────────────────────────────────────────────────

variable "enable_backup" {
  type        = bool
  description = "Enable weekly boot volume backups for all k3s nodes (Always Free: 5 total backups). With 4 nodes at weekly-1-week-retention there are at most 4 active backups."
  default     = true
}

# ── Object Storage ────────────────────────────────────────────────────────────

variable "enable_object_storage_state" {
  type        = bool
  description = "Provision an Always Free OCI Object Storage bucket for storing Terraform/OpenTofu state (S3-compatible API). See the terraform_state_backend output for the backend configuration snippet."
  default     = true
}

# ── Notifications ─────────────────────────────────────────────────────────────

variable "enable_notifications" {
  type        = bool
  description = "Create an OCI Notifications topic and wire it to Alertmanager as a webhook receiver (Always Free: 1M HTTPS + 3K email/month)."
  default     = false
}

variable "alertmanager_email" {
  type        = string
  description = "Optional email address to subscribe to the OCI Notifications topic. The subscriber must confirm via an OCI confirmation email."
  default     = null
}

# ── MySQL HeatWave ────────────────────────────────────────────────────────────

variable "enable_mysql" {
  type        = bool
  description = "Provision an Always Free MySQL HeatWave DB system (single node, 50 GB). Creates a Kubernetes Secret 'mysql-credentials' in the default namespace."
  default     = false
}

variable "mysql_shape" {
  type        = string
  description = "MySQL HeatWave shape. 'MySQL.Free' is the Always Free shape."
  default     = "MySQL.Free"
}

variable "mysql_admin_username" {
  type        = string
  description = "Admin username for the MySQL HeatWave DB system."
  default     = "admin"
}

# ── Vault ─────────────────────────────────────────────────────────────────────

variable "enable_vault" {
  type        = bool
  description = "Store cluster secrets (k3s_token, longhorn_ui_password, grafana_admin_password) in OCI Vault (Always Free: software keys + 150 secrets). Nodes fetch secrets via OCI CLI instance_principal at boot — plaintext values are removed from cloud-init user-data."
  default     = true
}
