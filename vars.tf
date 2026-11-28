# ── OCI placement ─────────────────────────────────────────────────────────────

variable "tenancy_ocid" {
  type        = string
  description = "Tenancy OCID (service lookups and the Object Storage namespace)."

  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.", var.tenancy_ocid))
    error_message = "tenancy_ocid must be a tenancy OCID (ocid1.tenancy...)."
  }
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment for every resource of the cluster (the tenancy OCID works)."

  validation {
    condition     = can(regex("^ocid1\\.(tenancy|compartment)\\.", var.compartment_ocid))
    error_message = "compartment_ocid must be a tenancy or compartment OCID."
  }
}

variable "availability_domain" {
  type        = string
  description = "Availability domain for the nodes and the database, e.g. \"RyPa:PHX-AD-1\"."

  validation {
    condition     = can(regex("^[^:]+:[A-Z0-9-]+-AD-[1-3]$", var.availability_domain))
    error_message = "availability_domain must look like \"<prefix>:<REGION>-AD-<n>\"."
  }
}

variable "cluster_name" {
  type        = string
  description = "Prefix of every display name and of the backup bucket name."
  default     = "k3s-oci"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,28}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 3-30 characters of lowercase letters, digits and hyphens."
  }
}

variable "freeform_tags" {
  type        = map(string)
  description = "Extra freeform tags added to every resource."
  default     = {}
}

# ── Nodes ─────────────────────────────────────────────────────────────────────

variable "nodes" {
  type = map(object({
    ocpus        = number
    memory_gbs   = number
    boot_gb      = number
    fault_domain = optional(string)
    ip_host      = number
  }))
  description = <<-EOT
    k3s servers, keyed by hostname; all of them run workloads. With
    datastore = "mysql" any number of servers share the database (2 by default);
    with "etcd" use 1 or 3 for a quorum. ip_host is the host number of the node's
    fixed private IP inside private_subnet_cidr; the first node by name is the one
    an etcd cluster starts on. The default fills the Pay As You Go Always Free A1
    allowance (4 OCPU / 24 GB) and the 200 GB block storage allowance.
  EOT
  default = {
    server-0 = { ocpus = 2, memory_gbs = 12, boot_gb = 100, fault_domain = "FAULT-DOMAIN-1", ip_host = 10 }
    server-1 = { ocpus = 2, memory_gbs = 12, boot_gb = 100, fault_domain = "FAULT-DOMAIN-2", ip_host = 11 }
  }

  validation {
    condition     = length(var.nodes) >= 1 && length(var.nodes) <= 5
    error_message = "nodes must hold 1 to 5 servers."
  }

  validation {
    condition     = alltrue([for k, n in var.nodes : can(regex("^[a-z0-9][a-z0-9-]{0,14}$", k))])
    error_message = "Node keys become hostnames and OCI hostname labels: up to 15 lowercase letters, digits and hyphens."
  }

  validation {
    condition     = alltrue([for n in var.nodes : n.boot_gb >= 50])
    error_message = "boot_gb must be at least 50 (OCI's minimum boot volume)."
  }

  validation {
    condition     = alltrue([for n in var.nodes : n.fault_domain == null || can(regex("^FAULT-DOMAIN-[1-3]$", n.fault_domain))])
    error_message = "fault_domain must be FAULT-DOMAIN-1, -2 or -3 (or null)."
  }
}

variable "os_family" {
  type        = string
  description = <<-EOT
    Image-based OS of every node:
    - "opensuse": openSUSE Leap Immutable (default). cloud-init runs the node script;
      packages go into a transactional-update snapshot (one reboot at first boot);
      security patches daily, the rest Tuesday to Thursday, kured reboots.
    - "fcos": Fedora CoreOS. Ignition fetches the node script through a read-only
      pre-authenticated request; OS updates are the fcos-os upgrade Plan
      (gitops/fcos-os/), one drained node at a time, as on OpenShift.
    - "flatcar": Flatcar Container Linux. Ignition only: k3s is a system extension
      from the Flatcar sysext bakery, patched by systemd-sysupdate within its minor;
      the OS updates itself (update_engine), kured reboots.
  EOT
  default     = "opensuse"

  validation {
    condition     = contains(["opensuse", "fcos", "flatcar"], var.os_family)
    error_message = "os_family must be opensuse, fcos or flatcar."
  }
}

variable "image_id" {
  type        = string
  description = <<-EOT
    OCID of the custom image the nodes boot from (scripts/import-image.sh imports
    it for os_family and prints the OCID; scripts/deploy.sh deletes it after the
    apply: custom images are billed while they exist, and instances keep their boot
    volumes). null only for plans.
  EOT
  default     = null

  validation {
    condition     = var.image_id == null || can(regex("^ocid1\\.image\\.", var.image_id))
    error_message = "image_id must be an image OCID (ocid1.image...)."
  }
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key of the nodes' default user (sles on opensuse, core on fcos and flatcar), for break-glass access through a Bastion session. null: no key."
  default     = null
}

# ── k3s ───────────────────────────────────────────────────────────────────────

variable "datastore" {
  type        = string
  description = <<-EOT
    "mysql" (default): every server keeps the cluster state in the free MySQL
    HeatWave database through kine, so etcd's fsync load is off the boot volumes
    and any server can be replaced on its own. Oracle backs the database up daily.
    "etcd": embedded etcd on the servers (1 or 3), snapshots to the backups bucket
    when etcd_s3_access_key is set.
  EOT
  default     = "mysql"

  validation {
    condition     = contains(["mysql", "etcd"], var.datastore)
    error_message = "datastore must be mysql or etcd."
  }
}

variable "k3s_channel" {
  type        = string
  description = "k3s release channel new nodes install from (stable, latest or a minor like v1.37), unless k3s_version pins a release. Running servers are upgraded by the system-upgrade-controller Plans in gitops/system-upgrade/."
  default     = "stable"
}

variable "k3s_version" {
  type        = string
  description = "Exact k3s release for new nodes (v1.37.2+k3s1), or null to follow k3s_channel. On os_family = flatcar it picks the sysext, and is required."
  # renovate: datasource=github-releases depName=k3s-io/k3s
  default = "v1.37.2+k3s1"

  validation {
    condition     = var.k3s_version == null || can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+\\+k3s[0-9]+$", var.k3s_version))
    error_message = "k3s_version must look like v1.37.2+k3s1."
  }
}

variable "k3s_extra_config" {
  type        = map(any)
  description = "Extra k3s config keys merged into the module's config drop-in (/etc/rancher/k3s/config.yaml.d/10-k3s-oci.yaml); a key here replaces the module's."
  default     = {}
}

variable "secrets_encryption" {
  type        = bool
  description = "Encrypt Secrets at rest in the datastore (k3s --secrets-encryption, secretbox)."
  default     = true
}

variable "etcd_s3_access_key" {
  type        = string
  description = "datastore = \"etcd\": access key of an OCI Customer Secret Key that may write the backups bucket (a bucket-scoped service user, never an admin). k3s uploads its etcd snapshots to the etcd/ prefix. null: snapshots stay on the servers."
  default     = null
  sensitive   = true
}

variable "etcd_s3_secret_key" {
  type        = string
  description = "Secret half of etcd_s3_access_key."
  default     = null
  sensitive   = true
}

# ── GitOps bootstrap ──────────────────────────────────────────────────────────

variable "argocd_chart_version" {
  type        = string
  description = "argo-cd Helm chart the servers install through k3s's HelmChart controller. Keep it equal to the version gitops/apps/argocd.yaml pins: that Application adopts the release."
  # renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm
  default = "10.18.0"
}

variable "gitops_repo_url" {
  type        = string
  description = "Git repository of the App of Apps. A fork of this module (gitops/update-repo-url.sh), or your own GitOps repository. \"\" skips Argo CD."
  default     = "https://github.com/mbologna/k3s-oci.git"
}

variable "gitops_revision" {
  type        = string
  description = "Branch, tag or commit of gitops_repo_url Argo CD follows."
  default     = "HEAD"
}

variable "gitops_path" {
  type        = string
  description = "Directory of the App of Apps in gitops_repo_url."
  default     = "gitops/apps"
}

variable "gitops_https_username" {
  type        = string
  description = "Username for a private gitops_repo_url over HTTPS (with gitops_https_token)."
  default     = ""
}

variable "gitops_https_token" {
  type        = string
  description = "Read token for a private gitops_repo_url. It is part of the node configuration (see SECURITY.md)."
  default     = ""
  sensitive   = true
}

variable "certmanager_email" {
  type        = string
  description = "Let's Encrypt account email: when set, the servers create the letsencrypt-staging and letsencrypt-prod ClusterIssuers (HTTP-01 through Traefik) once cert-manager runs."
  default     = null

  validation {
    condition     = var.certmanager_email == null || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.certmanager_email))
    error_message = "certmanager_email must be an email address."
  }
}

# ── OS specifics ──────────────────────────────────────────────────────────────

variable "fcos_os_version" {
  type        = string
  description = "os_family = fcos: the Fedora CoreOS release new nodes pivot to before k3s starts. Keep it equal to the fcos-os Plan's version (gitops/fcos-os/plan.yaml), which upgrades running nodes."
  # renovate: datasource=custom.fedora-coreos-release depName=fedora-coreos-release
  default = "45.20261030.3.1"
}

variable "fcos_stream" {
  type        = string
  description = "os_family = fcos: update stream whose graph the node follows (stable, testing, next)."
  default     = "stable"

  validation {
    condition     = contains(["stable", "testing", "next"], var.fcos_stream)
    error_message = "fcos_stream must be stable, testing or next."
  }
}

# ── Network ───────────────────────────────────────────────────────────────────

variable "vcn_cidr" {
  type        = string
  description = "VCN CIDR. Must not overlap pod_cidr or service_cidr."
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vcn_cidr, 0))
    error_message = "vcn_cidr must be a valid CIDR."
  }
}

variable "public_subnet_cidr" {
  type        = string
  description = "Public subnet (the network load balancer only)."
  default     = "10.0.0.0/24"
}

variable "private_subnet_cidr" {
  type        = string
  description = "Private subnet (nodes, internal load balancer, database, Bastion endpoint)."
  default     = "10.0.1.0/24"
}

variable "pod_cidr" {
  type        = string
  description = "Pod network (flannel, k3s's cluster-cidr)."
  default     = "10.42.0.0/16"

  validation {
    condition     = can(cidrhost(var.pod_cidr, 0))
    error_message = "pod_cidr must be a valid CIDR."
  }
}

variable "service_cidr" {
  type        = string
  description = "Service network (k3s's service-cidr)."
  default     = "10.43.0.0/16"

  validation {
    condition     = can(cidrhost(var.service_cidr, 0))
    error_message = "service_cidr must be a valid CIDR."
  }
}

variable "ingress_http_nodeport" {
  type        = number
  description = "NodePort of the ingress controller's HTTP entrypoint (the NLB forwards :80 here; gitops/apps/traefik.yaml uses it)."
  default     = 30080
}

variable "ingress_https_nodeport" {
  type        = number
  description = "NodePort of the ingress controller's HTTPS entrypoint (the NLB forwards :443 here)."
  default     = 30443
}

# ── Optional features ─────────────────────────────────────────────────────────

variable "enable_bastion" {
  type        = bool
  description = "Create an OCI Bastion for port forwarding to the Kubernetes API (6443, internal load balancer) and break-glass SSH to a node. scripts/tunnel.sh uses it."
  default     = true
}

variable "bastion_client_cidrs" {
  type        = list(string)
  description = "Client CIDRs allowed to open Bastion sessions (sessions also need your SSH key)."
  default     = ["0.0.0.0/0"]
}

variable "enable_boot_volume_backups" {
  type        = bool
  description = "Weekly boot-volume backups kept one week (one per node; Always Free allows 5)."
  default     = true
}

variable "mysql_shape" {
  type        = string
  description = "datastore = \"mysql\": shape of the MySQL HeatWave DB system. MySQL.Free is the Always Free one (1 per tenancy, 50 GB)."
  default     = "MySQL.Free"
}

variable "alert_email" {
  type        = string
  description = "Email for OCI Monitoring alarms (instance down, unhealthy NLB backends, failing uptime checks). null skips monitoring."
  default     = null
}

variable "uptime_urls" {
  type        = list(string)
  description = "HTTPS URLs checked every 10 minutes by a free-tier APM synthetic monitor (needs alert_email). Up to 10 runs an hour are free: keep this to one URL."
  default     = []

  validation {
    condition     = length(var.uptime_urls) <= 1
    error_message = "The free APM tier allows 10 synthetic runs an hour: one URL every 10 minutes."
  }
}

# ── Always Free guardrails ────────────────────────────────────────────────────

variable "a1_free_ocpus" {
  type        = number
  description = "Free A1 OCPUs of the tenancy: 4 on Pay As You Go (3,000 OCPU-hours a month), 2 on a never-upgraded Always Free tenancy."
  default     = 4
}

variable "a1_free_memory_gbs" {
  type        = number
  description = "Free A1 memory of the tenancy: 24 GB on Pay As You Go (18,000 GB-hours a month), 12 GB on a never-upgraded Always Free tenancy."
  default     = 24
}
