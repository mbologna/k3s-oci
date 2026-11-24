data "http" "k3s_channel" {
  count = contains(["stable", "latest"], var.k3s_version) ? 1 : 0
  url   = "https://update.k3s.io/v1-release/channels/${var.k3s_version}"

  request_headers = {
    Accept = "application/json"
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "k3s channel API returned ${self.status_code} when resolving '${var.k3s_version}' channel."
    }
  }
}

data "http" "github_ssh_keys" {
  count = var.github_ssh_keys_username != "" ? 1 : 0
  url   = "https://github.com/${var.github_ssh_keys_username}.keys"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Failed to fetch SSH keys for GitHub user '${var.github_ssh_keys_username}' (HTTP ${self.status_code})."
    }
  }
}

# Shared SSH host key distributed to all nodes so that SSHing through the NLB
# always presents the same fingerprint regardless of which backend is selected.
resource "tls_private_key" "ssh_host_key" {
  algorithm = "ED25519"
}

resource "random_password" "k3s_token" {
  length  = 64
  special = false

  # Only regenerate the token when the cluster identity changes, not on unrelated variable updates
  keepers = {
    cluster_name = var.cluster_name
  }
}

resource "random_password" "longhorn_ui_password" {
  length  = 24
  special = false

  keepers = {
    cluster_name = var.cluster_name
  }
}

# ── Server cloud-init vars (thematic locals for readability) ──────────────────
# These are merged on top of local.k3s_common_cloud_init_vars in the templatefile call.

locals {
  # Cluster identity and networking
  _server_identity_vars = {
    k3s_tls_san         = local.k3s_internal_lb_ip
    k3s_tls_san_public  = try(local.public_lb_ip[0], "")
    expose_kubeapi      = var.expose_kubeapi
    compartment_ocid    = var.compartment_ocid
    availability_domain = var.availability_domain
    cluster_name        = var.cluster_name
  }

  # GitOps source and deploy key
  _server_gitops_vars = {
    gitops_repo_url                    = var.gitops_repo_url
    gitops_path                        = var.gitops_path
    gitops_optional_path               = var.gitops_optional_path
    vault_secret_id_gitops_ssh_key     = var.enable_vault && var.gitops_ssh_private_key != "" ? try(oci_vault_secret.gitops_ssh_key[0].id, "") : ""
    gitops_https_username              = var.gitops_https_username
    vault_secret_id_gitops_https_token = var.enable_vault && var.gitops_https_token != "" ? try(oci_vault_secret.gitops_https_token[0].id, "") : ""
  }

  # Bootstrap chart versions (cloud-init installs; ArgoCD adopts ongoing management)
  _server_bootstrap_vars = {
    certmanager_email_address      = var.certmanager_email_address
    certmanager_chart_version      = var.certmanager_chart_version
    argocd_chart_version           = var.argocd_chart_version
    external_secrets_chart_version = var.external_secrets_chart_version
  }

  # Cluster secrets: plain-text fallback (empty when vault is enabled)
  _server_secret_vars = {
    longhorn_ui_username              = var.longhorn_ui_username
    longhorn_ui_password              = var.enable_vault ? "" : random_password.longhorn_ui_password.result
    vault_secret_id_longhorn_password = var.enable_vault ? try(oci_vault_secret.cluster["longhorn_ui_password"].id, "") : ""
    vault_ocid                        = var.enable_vault ? oci_kms_vault.k3s[0].id : ""
    # External Secrets service user (create_external_secrets_user): IDs only; the
    # private key is fetched from Vault at boot.
    eso_user_ocid               = local.create_external_secrets_user ? oci_identity_user.external_secrets[0].id : ""
    eso_api_key_fingerprint     = local.create_external_secrets_user ? oci_identity_api_key.external_secrets[0].fingerprint : ""
    eso_tenancy_ocid            = local.create_external_secrets_user ? var.tenancy_ocid : ""
    vault_secret_id_eso_api_key = local.create_external_secrets_user ? oci_vault_secret.external_secrets_api_key[0].id : ""
  }

  # Feature flags
  _server_feature_vars = {
    enable_external_dns     = var.enable_external_dns
    enable_external_secrets = var.enable_external_secrets
    enable_dns01_challenge  = var.enable_dns01_challenge
  }

  # Optional integrations (Cloudflare, MySQL, DockerHub)
  _server_optional_vars = {
    # Cloudflare: plaintext only when vault is disabled; vault secret ID used otherwise.
    cloudflare_api_token       = !var.enable_vault && var.cloudflare_api_token != null ? var.cloudflare_api_token : ""
    cloudflare_zone_id         = var.cloudflare_zone_id != null ? var.cloudflare_zone_id : ""
    external_dns_domain_filter = var.external_dns_domain_filter != null ? var.external_dns_domain_filter : ""
    vault_secret_id_cloudflare = var.enable_vault && var.cloudflare_api_token != null ? oci_vault_secret.cloudflare_api_token[0].id : ""
    oci_region                 = var.region != null ? var.region : ""
    mysql_endpoint             = var.enable_mysql ? "${oci_mysql_mysql_db_system.k3s[0].endpoints[0].hostname}:${oci_mysql_mysql_db_system.k3s[0].endpoints[0].port}" : ""
    mysql_admin_username       = var.enable_mysql ? var.mysql_admin_username : ""
    mysql_admin_password       = var.enable_mysql ? random_password.mysql_admin_password[0].result : ""
    dockerhub_username         = var.dockerhub_username
    # DockerHub password: plaintext only when vault is disabled or not set.
    # When vault is enabled and a password is configured, the plaintext is blanked here
    # and create_dockerhub_secret() in k3s-argocd.sh fetches it from Vault instead.
    dockerhub_password        = var.enable_vault && var.dockerhub_password != "" ? "" : var.dockerhub_password
    vault_secret_id_dockerhub = var.enable_vault && var.dockerhub_password != "" ? oci_vault_secret.dockerhub_password[0].id : ""
  }

  # etcd snapshot upload and Longhorn backup target vars
  _server_backup_vars = {
    enable_etcd_snapshots      = var.enable_etcd_snapshots
    etcd_snapshot_bucket       = var.enable_etcd_snapshots && var.enable_object_storage_state ? "${var.cluster_name}-terraform-state" : ""
    etcd_snapshot_retention    = var.etcd_snapshot_retention
    etcd_snapshot_upload_hours = var.etcd_snapshot_upload_hours
    oci_object_namespace       = local.oci_object_namespace
    # Separate lock bucket: driven by enable_object_storage_state alone, independent of
    # enable_etcd_snapshots. Disabling etcd snapshots must NOT disable split-brain protection.
    cluster_lock_bucket    = var.enable_object_storage_state ? "${var.cluster_name}-terraform-state" : ""
    enable_longhorn_backup = var.enable_longhorn_backup
    longhorn_backup_bucket = var.enable_longhorn_backup ? "${var.cluster_name}-longhorn-backup" : ""
    # S3-compatible endpoint + key: set when Terraform owns the key (create_longhorn_backup_user
    # or user_ocid). region is required then (longhorn_backup_requires_region check).
    longhorn_backup_endpoint   = local.longhorn_backup_automated ? "https://${local.oci_object_namespace}.compat.objectstorage.${var.region}.oraclecloud.com" : ""
    longhorn_backup_access_key = local.longhorn_backup_automated ? oci_identity_customer_secret_key.longhorn_backup[0].id : ""
    # Secret key: plaintext only when vault is disabled; fetched from Vault otherwise.
    longhorn_backup_secret_key          = local.longhorn_backup_automated && !var.enable_vault ? oci_identity_customer_secret_key.longhorn_backup[0].key : ""
    vault_secret_id_longhorn_backup_key = local.longhorn_backup_automated && var.enable_vault ? oci_vault_secret.longhorn_backup_secret_key[0].id : ""
    longhorn_backup_schedule            = var.longhorn_backup_schedule
    longhorn_backup_retain              = var.longhorn_backup_retain
  }

  # Hostname vars: IP-specific, derived at plan time from the NLB IP
  _server_hostname_vars = {
    argocd_hostname   = local.argocd_hostname
    longhorn_hostname = local.longhorn_hostname
    # external-dns target for the Ingresses cloud-init creates (Traefik
    # publishes no Ingress status behind the NLB).
    public_nlb_ip = try(local.public_lb_ip[0], "")
  }

  # Extra k3s server args (e.g. etcd tuning)
  _server_extra_args_vars = {
    k3s_extra_server_args           = join(" ", var.k3s_extra_server_args)
    k3s_secrets_encryption          = var.k3s_secrets_encryption # gitleaks:allow (a bool flag, not a secret)
    k3s_secrets_encryption_provider = var.k3s_secrets_encryption_provider
    # Custom cluster CA (user-created Vault secret), seeded before --cluster-init
    k3s_ca_vault_secret_id = var.k3s_ca_vault_secret_id != null ? var.k3s_ca_vault_secret_id : "" # gitleaks:allow (a secret's OCID, not a secret)
  }

  # Debug
  _server_debug_vars = {
    trace_enabled = var.trace_enabled
  }

  # OS vars: SSH user and key (the bootstrap script itself is selected by var.os_family below).
  _server_os_vars = {
    os_user        = local.os_user
    ssh_public_key = local.ssh_public_key
  }

  # Final merged map passed to the server templatefile
  k3s_server_cloud_init_vars = merge(
    local.k3s_common_cloud_init_vars,
    local._server_identity_vars,
    local._server_gitops_vars,
    local._server_bootstrap_vars,
    local._server_secret_vars,
    local._server_feature_vars,
    local._server_optional_vars,
    local._server_backup_vars,
    local._server_hostname_vars,
    local._server_extra_args_vars,
    local._server_debug_vars,
    local._server_os_vars,
  )
}

# Strip pure comment lines (lines that are only "# ...") from shell scripts.
# This keeps shebangs (#!/), blank lines, and inline comments after code.
# Required: OCI instance metadata has a hard 32KB limit; the cloud-init payload
# with all comments exceeds this. Comments are preserved in source files (git).
locals {
  _sc = "(?m)^[ \\t]*#[^!][^\\n]*"

  # OS bootstrap (bootstrap() and configure_unattended_upgrades()), by var.os_family.
  os_bootstrap_file = {
    ubuntu   = "bootstrap-ubuntu.sh"
    opensuse = var.opensuse_variant == "immutable" ? "bootstrap-opensuse-immutable.sh" : "bootstrap-opensuse.sh"
    fcos     = "bootstrap-fcos.sh"
  }[var.os_family]

  # Image-based OSes install packages into a new snapshot and reboot into it before
  # anything else runs: files/lib/two-phase.sh persists the script and runs it again
  # after the reboot, two-phase-done.sh retires it.
  two_phase = var.os_family == "fcos" || (var.os_family == "opensuse" && var.opensuse_variant == "immutable")

  # Node scripts, in order: rendered vars header, OS bootstrap, shared helpers, entry
  # point. The empty lists leave the scripts of one-phase OSes exactly as they were.
  _server_script_files = concat(
    [local.os_bootstrap_file],
    local.two_phase ? ["two-phase.sh"] : [],
    [
      "common.sh",
      "k3s-secrets.sh",
      "k3s-cert-manager.sh",
      "k3s-external-secrets.sh",
      "k3s-argocd.sh",
      "k3s-bootstrap.sh",
      "k3s-server.sh",
    ],
    # FCOS OS updates are an upgrade Plan, an Argo CD app the first server adds.
    var.os_family == "fcos" ? ["k3s-fcos-os.sh"] : [],
    local.two_phase ? ["two-phase-done.sh"] : [],
  )
  _worker_script_files = concat(
    [local.os_bootstrap_file],
    local.two_phase ? ["two-phase.sh"] : [],
    ["common.sh", "k3s-agent.sh"],
    local.two_phase ? ["two-phase-done.sh"] : [],
  )

  k3s_server_script = join("\n", concat(
    [templatefile("${path.module}/files/server-vars.sh.tpl", local.k3s_server_cloud_init_vars)],
    [for f in local._server_script_files : replace(file("${path.module}/files/lib/${f}"), "/${local._sc}/", "")],
  ))
  k3s_worker_script = join("\n", concat(
    [templatefile("${path.module}/files/agent-vars.sh.tpl", merge(local.k3s_common_cloud_init_vars, {
      trace_enabled  = var.trace_enabled
      os_user        = local.os_user
      ssh_public_key = local.ssh_public_key
    }))],
    [for f in local._worker_script_files : replace(file("${path.module}/files/lib/${f}"), "/${local._sc}/", "")],
  ))
}

data "cloudinit_config" "k3s_server" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content      = local.k3s_server_script
  }
}

data "cloudinit_config" "k3s_worker" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content      = local.k3s_worker_script
  }
}


# ── Fedora CoreOS: Ignition instead of cloud-init ─────────────────────────────
# FCOS reads only Ignition, from user_data, as base64 of plain JSON (its OCI provider
# does not gunzip). The server script inlined there would be base64 twice and exceed
# OCI's 32,000-byte metadata limit, so Ignition fetches it from the state bucket
# through a read-only pre-authenticated request (objectstorage.tf), and runs it from
# the same unit two-phase.sh installs (keep the two unit texts in step).

locals {
  _fcos_bootstrap_unit = <<-EOT
    [Unit]
    Description=k3s-oci node bootstrap (runs until it completes once)
    Wants=network-online.target
    After=network-online.target
    ConditionPathExists=!/var/lib/k3s-oci/done

    [Service]
    Type=oneshot
    Environment=HOME=/root
    WorkingDirectory=/root
    ExecStart=/usr/bin/bash /var/lib/k3s-oci/bootstrap.sh
    TimeoutStartSec=infinity

    [Install]
    WantedBy=multi-user.target
  EOT

  fcos_ignition = {
    for role in ["server", "worker"] : role => base64encode(jsonencode({
      ignition = { version = "3.4.0" }
      storage = {
        directories = [{ path = "/var/lib/k3s-oci", mode = 448 }]
        files = [
          {
            path     = "/var/lib/k3s-oci/bootstrap.sh"
            mode     = 448
            contents = { source = oci_objectstorage_preauthrequest.fcos_script[role].full_path }
          },
          {
            # The release new nodes pivot to before k3s starts (bootstrap-fcos.sh).
            path     = "/etc/k3s-oci/fcos-os-version"
            mode     = 420
            contents = { source = "data:,${var.fcos_os_version}" }
          },
        ]
      }
      systemd = {
        units = [
          { name = "k3s-oci-bootstrap.service", enabled = true, contents = local._fcos_bootstrap_unit },
          # OS updates are a cluster operation (the fcos-os Plan), as on OpenShift.
          { name = "zincati.service", mask = true },
        ]
      }
    })) if var.os_family == "fcos"
  }

  # What the instance configurations and the standalone worker get as user_data.
  # (lookup: HCL evaluates both branches, and fcos_ignition is empty for other OSes.)
  k3s_server_user_data = var.os_family == "fcos" ? lookup(local.fcos_ignition, "server", "") : data.cloudinit_config.k3s_server.rendered
  k3s_worker_user_data = var.os_family == "fcos" ? lookup(local.fcos_ignition, "worker", "") : data.cloudinit_config.k3s_worker.rendered
}

data "oci_core_instance_pool_instances" "k3s_servers" {
  depends_on       = [oci_core_instance_pool.k3s_servers]
  compartment_id   = var.compartment_ocid
  instance_pool_id = oci_core_instance_pool.k3s_servers.id
}

data "oci_core_instance" "k3s_servers" {
  count       = var.k3s_server_pool_size
  instance_id = data.oci_core_instance_pool_instances.k3s_servers.instances[count.index].id
}

data "oci_core_instance_pool_instances" "k3s_workers" {
  depends_on       = [oci_core_instance_pool.k3s_workers]
  compartment_id   = var.compartment_ocid
  instance_pool_id = oci_core_instance_pool.k3s_workers.id
}

data "oci_core_instance" "k3s_workers" {
  count       = var.k3s_worker_pool_size
  instance_id = data.oci_core_instance_pool_instances.k3s_workers.instances[count.index].id
}

# ── k3s node image (Ubuntu LTS aarch64 — A1.Flex) ──────────────────────────
# Auto-resolved from tenancy when os_family = "ubuntu" and os_image_id is not set.
data "oci_core_images" "k3s_nodes" {
  count                    = var.os_family == "ubuntu" && var.os_image_id == null ? 1 : 0
  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = var.ubuntu_version
  shape                    = var.compute_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  lifecycle {
    postcondition {
      condition     = length(self.images) > 0
      error_message = "No Ubuntu ${var.ubuntu_version} image found for shape ${var.compute_shape} in tenancy. Set os_image_id explicitly."
    }
  }
}

# ── k3s node image (openSUSE Leap aarch64 custom import) ───────────────────
# Auto-resolved when os_family = "opensuse" and os_image_id is not set: every image that
# scripts/import-opensuse-aarch64.sh imported for opensuse_variant (operating system
# "openSUSE Leap", or "openSUSE Leap Immutable"). locals.tf picks
# the newest one of opensuse_leap_version, falling back to the newest of any release (checks.tf warns).
data "oci_core_images" "opensuse" {
  count            = var.os_family == "opensuse" && var.os_image_id == null ? 1 : 0
  compartment_id   = coalesce(var.opensuse_image_compartment_ocid, var.tenancy_ocid)
  operating_system = local.opensuse_operating_system
  shape            = var.compute_shape
  state            = "AVAILABLE"
  sort_by          = "TIMECREATED"
  sort_order       = "DESC"

  lifecycle {
    postcondition {
      condition     = length(self.images) > 0
      error_message = "No imported ${local.opensuse_operating_system} image found for shape ${var.compute_shape} in compartment ${coalesce(var.opensuse_image_compartment_ocid, var.tenancy_ocid)}. Run scripts/import-opensuse-aarch64.sh --leap-version ${var.opensuse_leap_version} --variant ${var.opensuse_variant} (re-running it also tags images imported by older versions of the script), or set os_image_id."
    }
  }
}

# Pinned openSUSE image, read so checks.tf can compare its release with opensuse_leap_version.
data "oci_core_image" "opensuse" {
  count    = var.os_family == "opensuse" && var.os_image_id != null ? 1 : 0
  image_id = var.os_image_id
}

# ── k3s node image (Fedora CoreOS aarch64 custom import) ──────────────────────
# Auto-resolved when os_family = "fcos" and os_image_id is not set: every image that
# scripts/import-fcos-aarch64.sh imported (operating system "Fedora CoreOS", version
# the Fedora major). locals.tf picks the newest one of fcos_version, falling back to
# the newest of any release (checks.tf warns).
data "oci_core_images" "fcos" {
  count            = var.os_family == "fcos" && var.os_image_id == null ? 1 : 0
  compartment_id   = coalesce(var.fcos_image_compartment_ocid, var.tenancy_ocid)
  operating_system = "Fedora CoreOS"
  shape            = var.compute_shape
  state            = "AVAILABLE"
  sort_by          = "TIMECREATED"
  sort_order       = "DESC"

  lifecycle {
    postcondition {
      condition     = length(self.images) > 0
      error_message = "No imported Fedora CoreOS image found for shape ${var.compute_shape} in compartment ${coalesce(var.fcos_image_compartment_ocid, var.tenancy_ocid)}. Run scripts/import-fcos-aarch64.sh, or set os_image_id."
    }
  }
}

# Pinned Fedora CoreOS image, read so checks.tf can compare its release with fcos_version.
data "oci_core_image" "fcos" {
  count    = var.os_family == "fcos" && var.os_image_id != null ? 1 : 0
  image_id = var.os_image_id
}
