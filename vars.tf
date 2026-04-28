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

variable "github_ssh_keys_username" {
  type        = string
  description = <<-EOT
    GitHub username whose published SSH keys (https://github.com/<username>.keys)
    are added to every instance's authorized_keys at plan time, in addition to
    the primary public_key / public_key_path. Leave empty to skip.
  EOT
  default     = ""
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
  description = "When true, no ingress controller is installed (skips Envoy Gateway install)"
  default     = false
}

# ── cert-manager (always installed — keeps cluster active, avoids idle reclamation) ───

variable "certmanager_email_address" {
  type        = string
  description = "Email address for Let's Encrypt ACME registration. Must be a real address."

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.certmanager_email_address)) && var.certmanager_email_address != "changeme@example.com"
    error_message = "certmanager_email_address must be a valid email address (not the placeholder)."
  }
}

# ── ArgoCD (always installed — GitOps controller keeps cluster active) ────────

variable "argocd_hostname" {
  type        = string
  description = "Fully-qualified hostname for the ArgoCD UI (e.g. argocd.example.com). When set, a Gateway API HTTPRoute with a cert-manager TLS certificate is created."
  default     = null
}

variable "longhorn_hostname" {
  type        = string
  description = "Fully-qualified hostname for the Longhorn UI (e.g. longhorn.example.com). When set, a Gateway API HTTPRoute with BasicAuth (Envoy Gateway SecurityPolicy) and a cert-manager TLS certificate is created."
  default     = null
}

variable "longhorn_ui_username" {
  type        = string
  description = "Username for Longhorn UI BasicAuth (only used when longhorn_hostname is set)."
  default     = "admin"
}

variable "grafana_hostname" {
  type        = string
  description = "Fully-qualified hostname for the Grafana UI (e.g. grafana.example.com). When set, a Gateway API HTTPRoute with a cert-manager TLS certificate is created in gitops/monitoring/."
  default     = null
}

variable "gitops_repo_url" {
  type        = string
  description = "Git repository URL for the ArgoCD App of Apps (e.g. https://github.com/your-org/k3s-oci.git). Set this to your fork so ArgoCD pulls from the right repo."
  default     = "https://github.com/mbologna/k3s-oci.git"
}

# ── kured (always installed — graceful kernel reboot management) ──────────────

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
# OCI CLI is installed at latest available version at bootstrap time.
# It is only used during node initialisation for Vault secret fetch and is
# not a running workload — no versioning needed.

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

variable "enable_longhorn_backup" {
  type        = bool
  description = "Provision a dedicated Always Free OCI Object Storage bucket for Longhorn PVC backups (S3-compatible). See longhorn_backup_setup output for connection instructions. Shares the 20 GB free allowance with the Terraform state bucket."
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

# ── External DNS (Cloudflare) ─────────────────────────────────────────────────

variable "enable_external_dns" {
  type        = bool
  description = "Deploy external-dns (kubernetes-sigs) configured for Cloudflare. Automatically creates/updates DNS A records when Services or Ingresses are annotated. Requires cloudflare_api_token and cloudflare_zone_id."
  default     = false
}

variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token. Required when enable_external_dns = true or enable_dns01_challenge = true. Create a scoped token at https://dash.cloudflare.com/profile/api-tokens with Zone:DNS:Edit permissions."
  default     = null
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare Zone ID for the managed domain. Required when enable_external_dns = true."
  default     = null
}

variable "external_dns_domain_filter" {
  type        = string
  description = "Domain filter for external-dns — only DNS records under this domain are managed (e.g. 'k3s.example.com'). Required when enable_external_dns = true."
  default     = null
}

# ── External Secrets Operator ─────────────────────────────────────────────────

variable "enable_external_secrets" {
  type        = bool
  description = "Deploy the External Secrets Operator and create a ClusterSecretStore backed by OCI Vault (instance_principal auth). Requires enable_vault = true. Workloads can then create ExternalSecret resources to sync any OCI Vault secret into a Kubernetes Secret without hard-coding values."
  default     = false
}

variable "region" {
  type        = string
  description = "OCI region identifier (e.g. 'eu-frankfurt-1'). Required when enable_external_secrets = true for the ClusterSecretStore to locate the OCI Vault endpoint."
  default     = null
}

# ── DNS-01 ACME challenge via Cloudflare ──────────────────────────────────────

variable "enable_dns01_challenge" {
  type        = bool
  description = "Configure cert-manager ClusterIssuers to use DNS-01 ACME challenge via Cloudflare instead of HTTP-01. Enables wildcard certificates (*.example.com) and works even without inbound port 80. Requires cloudflare_api_token."
  default     = false
}

# Bootstrap chart versions — must match the targetRevision in the corresponding
# gitops/apps/*.yaml. Renovate keeps both in sync via a single PR.
# The bootstrap install uses this version so the cluster never starts with a
# chart that is newer than what ArgoCD would reconcile to.

variable "traefik_chart_version" {
  type        = string
  description = "Traefik Helm chart version — kept for state compatibility, not used when Envoy Gateway is enabled."
  default     = "39.0.8"
}

variable "gateway_api_version" {
  type        = string
  description = "Kubernetes Gateway API CRDs version (standard channel) installed at bootstrap."
  # renovate: datasource=github-releases depName=kubernetes-sigs/gateway-api
  default = "v1.5.1"
}

variable "envoy_gateway_chart_version" {
  type        = string
  description = "Envoy Gateway Helm chart version used for the bootstrap install. Must match gitops/apps/envoy-gateway.yaml targetRevision. Managed by Renovate."
  # renovate: datasource=github-releases depName=envoyproxy/gateway
  default = "v1.3.0"
}

variable "certmanager_chart_version" {
  type        = string
  description = "cert-manager Helm chart version used for the bootstrap install. Must match gitops/apps/cert-manager.yaml targetRevision. Managed by Renovate."
  # renovate: datasource=helm depName=cert-manager registryUrl=https://charts.jetstack.io
  default = "v1.20.2"
}

variable "longhorn_chart_version" {
  type        = string
  description = "Longhorn Helm chart version used for the bootstrap install. Must match gitops/apps/longhorn.yaml targetRevision. Managed by Renovate."
  # renovate: datasource=helm depName=longhorn registryUrl=https://charts.longhorn.io
  default = "1.11.1"
}

variable "argocd_chart_version" {
  type        = string
  description = "ArgoCD Helm chart version used for the bootstrap install. Must match gitops/apps/argocd.yaml targetRevision. Managed by Renovate."
  # renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm
  default = "9.5.5"
}

variable "kured_chart_version" {
  type        = string
  description = "kured Helm chart version used for the bootstrap install. Must match gitops/apps/kured.yaml targetRevision. Managed by Renovate."
  # renovate: datasource=helm depName=kured registryUrl=https://kubereboot.github.io/charts
  default = "5.11.0"
}

variable "external_dns_chart_version" {
  type        = string
  description = "external-dns Helm chart version used for the bootstrap install. Must match gitops/apps/external-dns.yaml targetRevision. Managed by Renovate."
  # renovate: datasource=helm depName=external-dns registryUrl=https://kubernetes-sigs.github.io/external-dns
  default = "1.20.0"
}

variable "external_secrets_chart_version" {
  type        = string
  description = "External Secrets Operator Helm chart version used for the bootstrap install. Must match gitops/apps/external-secrets.yaml targetRevision. Managed by Renovate."
  # renovate: datasource=helm depName=external-secrets registryUrl=https://charts.external-secrets.io
  default = "0.18.2"
}
