# What each node boots with: its k3s config, the cluster bootstrap manifests,
# and one bash script for every OS (files/), delivered by cloud-init (opensuse)
# or by Ignition through a read-only pre-authenticated request (fcos, flatcar).

locals {
  # The OCI S3-compatible endpoint, for k3s's etcd snapshots.
  s3_endpoint = "${data.oci_objectstorage_namespace.this.namespace}.compat.objectstorage.${local.region_name}.oraclecloud.com"
  etcd_s3     = var.datastore == "etcd" && var.etcd_s3_access_key != null

  # The module's k3s settings, a drop-in that sorts before anything a consumer
  # adds (/etc/rancher/k3s/config.yaml.d/10-k3s-oci.yaml). Notes:
  # - traefik, servicelb: the upstream Traefik chart from gitops/apps serves the
  #   NLB's NodePorts; local-storage: Longhorn is the default StorageClass.
  # - kubelet: image GC from 70 % (images, Longhorn replicas and, with etcd, the
  #   datastore share the boot volume); system-reserved for k3s, containerd and
  #   the pods' shims, which stay in k3s's cgroup; memory eviction, which k3s
  #   leaves out (the disk signals are k3s's own, repeated because the flag
  #   replaces the list).
  # - the etcd snapshot schedule avoids the top of the hour, where a user's cron
  #   jobs tend to sit.
  k3s_config = {
    for name, node in var.nodes : name => merge(
      {
        "node-name"             = name
        "node-ip"               = local.node_ips[name]
        "advertise-address"     = local.node_ips[name]
        "token"                 = random_password.k3s_token.result
        "tls-san"               = [local.lb_ip, "127.0.0.1"]
        "cluster-cidr"          = var.pod_cidr
        "service-cidr"          = var.service_cidr
        "disable"               = ["traefik", "servicelb", "local-storage"]
        "node-label"            = ["k3s-oci.io/os=${var.os_family}"]
        "write-kubeconfig-mode" = "0600"
        "secrets-encryption"    = var.secrets_encryption
        "kubelet-arg" = [
          "image-gc-high-threshold=70",
          "image-gc-low-threshold=55",
          "system-reserved=cpu=200m,memory=2Gi",
          "eviction-hard=memory.available<300Mi,imagefs.available<5%,nodefs.available<5%",
          "eviction-minimum-reclaim=memory.available=100Mi,imagefs.available=10%,nodefs.available=10%",
        ]
      },
      var.datastore == "mysql" ? { "datastore-endpoint" = local.kine_endpoint } : {},
      var.datastore == "etcd" && name == local.first_node ? { "cluster-init" = true } : {},
      var.datastore == "etcd" && name != local.first_node ? { "server" = "https://${local.first_ip}:6443" } : {},
      var.datastore == "etcd" ? { "etcd-snapshot-schedule-cron" = "17 */12 * * *" } : {},
      local.etcd_s3 ? {
        "etcd-s3"                    = true
        "etcd-s3-endpoint"           = local.s3_endpoint
        "etcd-s3-region"             = local.region_name
        "etcd-s3-bucket"             = oci_objectstorage_bucket.backups.name
        "etcd-s3-folder"             = "etcd"
        "etcd-s3-bucket-lookup-type" = "path"
        "etcd-s3-access-key"         = var.etcd_s3_access_key
        "etcd-s3-secret-key"         = var.etcd_s3_secret_key
      } : {},
      var.k3s_extra_config,
    )
  }

  # Manifests k3s's deploy controller applies from every server's
  # /var/lib/rancher/k3s/server/manifests/ (it retries until their CRDs exist):
  # Argo CD's repository credentials and the App of Apps, the Let's Encrypt
  # ClusterIssuers, and on Fedora CoreOS the OS upgrade Plan's Application.
  # Argo CD itself is installed once by the first server's script (Helm), and
  # adopted by gitops/apps/argocd.yaml.
  bootstrap_manifests = join("\n---\n", concat(
    var.gitops_repo_url != "" ? [yamlencode({
      apiVersion = "v1"
      kind       = "Namespace"
      metadata   = { name = "argocd" }
    })] : [],
    var.gitops_repo_url != "" && var.gitops_https_token != "" ? [yamlencode({
      apiVersion = "v1"
      kind       = "Secret"
      metadata = {
        name      = "argocd-repo-gitops"
        namespace = "argocd"
        labels    = { "argocd.argoproj.io/secret-type" = "repository" }
      }
      type = "Opaque"
      stringData = {
        type     = "git"
        url      = var.gitops_repo_url
        username = var.gitops_https_username
        password = var.gitops_https_token
      }
    })] : [],
    var.gitops_repo_url != "" ? [yamlencode({
      apiVersion = "argoproj.io/v1alpha1"
      kind       = "Application"
      metadata = {
        name       = "app-of-apps"
        namespace  = "argocd"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
      }
      spec = {
        project     = "default"
        source      = { repoURL = var.gitops_repo_url, targetRevision = var.gitops_revision, path = var.gitops_path }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy  = { automated = { prune = true, selfHeal = true } }
      }
    })] : [],
    var.gitops_repo_url != "" && var.os_family == "fcos" ? [yamlencode({
      apiVersion = "argoproj.io/v1alpha1"
      kind       = "Application"
      metadata   = { name = "optional-fcos-os", namespace = "argocd" }
      spec = {
        project     = "default"
        source      = { repoURL = var.gitops_repo_url, targetRevision = var.gitops_revision, path = "gitops/optional", directory = { include = "fcos-os.yaml" } }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy  = { automated = { prune = true, selfHeal = true } }
      }
    })] : [],
    var.certmanager_email != null ? [for env, server in {
      staging = "https://acme-staging-v02.api.letsencrypt.org/directory"
      prod    = "https://acme-v02.api.letsencrypt.org/directory"
      } : yamlencode({
        apiVersion = "cert-manager.io/v1"
        kind       = "ClusterIssuer"
        metadata   = { name = "letsencrypt-${env}" }
        spec = {
          acme = {
            email               = var.certmanager_email
            server              = server
            privateKeySecretRef = { name = "letsencrypt-${env}" }
            # The solver's Ingress listens on :80; Traefik redirects everything
            # else there to HTTPS at a lower priority.
            solvers = [{ http01 = { ingress = {
              ingressClassName = "traefik"
              ingressTemplate  = { metadata = { annotations = { "traefik.ingress.kubernetes.io/router.entrypoints" = "web" } } }
            } } }]
          }
        }
    })] : [],
  ))

  node_script = {
    for name, node in var.nodes : name => join("\n", concat(
      [templatefile("${path.module}/files/node-vars.sh.tpl", {
        cluster_name         = var.cluster_name
        node_name            = name
        first_node           = name == local.first_node
        os_family            = var.os_family
        os_user              = local.os_user
        ssh_public_key       = coalesce(var.ssh_public_key, "")
        k3s_channel          = var.k3s_channel
        k3s_version          = coalesce(var.k3s_version, "")
        k3s_config_b64       = base64encode(yamlencode(local.k3s_config[name]))
        manifests_b64        = base64encode(local.bootstrap_manifests)
        ca_files             = local.ca_files
        argocd_chart_version = var.gitops_repo_url != "" ? var.argocd_chart_version : ""
        fcos_stream          = var.fcos_stream
      })],
      [for f in local.script_files : file("${path.module}/files/lib/${f}")],
    ))
  }

  # Order: the vars header (above), the OS bootstrap, the run-until-done unit
  # (and the reboot into staged packages, opensuse and fcos), shared helpers,
  # the entry point, and the marker that retires the unit.
  script_files = [
    "bootstrap-${var.os_family}.sh",
    "two-phase.sh",
    "common.sh",
    "k3s.sh",
    "two-phase-done.sh",
  ]
}

# ── opensuse: cloud-init ──────────────────────────────────────────────────────

data "cloudinit_config" "node" {
  for_each = var.os_family == "opensuse" ? var.nodes : {}

  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content      = local.node_script[each.key]
  }
}

# ── fcos, flatcar: Ignition ───────────────────────────────────────────────────
# Ignition reads user_data as base64 of plain JSON (no gzip), so the script
# would not fit OCI's 32,000-byte metadata limit inline: it is an object in the
# backups bucket, fetched once at first boot through a read-only pre-authenticated
# request. Whoever can read user_data can read the URL, and so the script: the
# same principals that can read the script inline on opensuse.

resource "oci_objectstorage_object" "node_script" {
  for_each = local.uses_ignition ? var.nodes : {}

  namespace    = data.oci_objectstorage_namespace.this.namespace
  bucket       = oci_objectstorage_bucket.backups.name
  object       = "k3s-oci/${each.key}.sh"
  content_type = "text/x-shellscript"
  content      = local.node_script[each.key]
}

resource "oci_objectstorage_preauthrequest" "node_script" {
  for_each = oci_objectstorage_object.node_script

  namespace    = each.value.namespace
  bucket       = each.value.bucket
  name         = "${var.cluster_name}-${each.key}-script"
  access_type  = "ObjectRead"
  object_name  = each.value.object
  time_expires = "2100-01-01T00:00:00Z"

  lifecycle {
    # A replaced node boots from the same Ignition config, so the URL must
    # outlive the cluster; OCI may also return the time in another format.
    ignore_changes = [time_expires]
  }
}

locals {
  # Same unit as two-phase.sh installs (keep the two in step): it runs the
  # script at every boot until it completes once.
  bootstrap_unit = <<-EOT
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

  # Flatcar: k3s is a system extension from the Flatcar sysext bakery, merged
  # into /usr at boot; systemd-sysupdate stages its patch releases (within the
  # minor) and flags /run/reboot-required, which kured reads.
  flatcar_k3s_minor = var.k3s_version == null ? "" : regex("^(v[0-9]+\\.[0-9]+)", var.k3s_version)[0]
  flatcar_sysext    = var.k3s_version == null ? "" : "k3s-${var.k3s_version}-arm64.raw"

  ignition_config = {
    for name, node in var.nodes : name => jsonencode({
      ignition = { version = "3.4.0" }
      passwd = {
        users = [for key in [coalesce(var.ssh_public_key, "")] : { name = "core", sshAuthorizedKeys = [key] } if key != ""]
      }
      storage = {
        directories = [{ path = "/var/lib/k3s-oci", mode = 448 }]
        files = concat(
          [{
            path     = "/var/lib/k3s-oci/bootstrap.sh"
            mode     = 448
            contents = { source = try(oci_objectstorage_preauthrequest.node_script[name].full_path, "") }
          }],
          var.os_family == "fcos" ? [{
            # The release new nodes pivot to before k3s starts (bootstrap-fcos.sh).
            path     = "/etc/k3s-oci/fcos-os-version"
            mode     = 420
            contents = { source = "data:,${var.fcos_os_version}" }
          }] : [],
          var.os_family == "flatcar" ? [
            {
              path     = "/opt/extensions/k3s/${local.flatcar_sysext}"
              mode     = 420
              contents = { source = "https://extensions.flatcar.org/extensions/${local.flatcar_sysext}" }
            },
            {
              path     = "/etc/sysupdate.k3s.d/k3s-${local.flatcar_k3s_minor}.conf"
              mode     = 420
              contents = { source = "https://extensions.flatcar.org/extensions/k3s/k3s-${local.flatcar_k3s_minor}.conf" }
            },
            {
              path     = "/etc/sysupdate.d/noop.conf"
              mode     = 420
              contents = { source = "https://extensions.flatcar.org/extensions/noop.conf" }
            },
            {
              # update_engine downloads OS updates; kured reboots (bootstrap-flatcar.sh).
              path     = "/etc/flatcar/update.conf"
              mode     = 420
              contents = { source = "data:,REBOOT_STRATEGY%3Doff%0A" }
            },
          ] : [],
        )
        links = var.os_family == "flatcar" ? [{
          path   = "/etc/extensions/k3s.raw"
          target = "/opt/extensions/k3s/${local.flatcar_sysext}"
          hard   = false
        }] : []
      }
      systemd = {
        units = concat(
          [{ name = "k3s-oci-bootstrap.service", enabled = true, contents = local.bootstrap_unit }],
          # Fedora CoreOS: OS updates are a cluster operation (the fcos-os Plan).
          [for u in [{ name = "zincati.service", mask = true }] : u if var.os_family == "fcos"],
          # Flatcar: kured reboots, not locksmith.
          [for u in [
            { name = "locksmithd.service", mask = true },
            { name = "systemd-sysupdate.timer", enabled = true },
            {
              name = "systemd-sysupdate.service"
              dropins = [{
                name     = "k3s.conf"
                contents = <<-EOT
                  [Service]
                  ExecStartPre=/usr/bin/sh -c "readlink --canonicalize /etc/extensions/k3s.raw > /tmp/k3s"
                  ExecStartPre=/usr/lib/systemd/systemd-sysupdate -C k3s update
                  ExecStartPost=/usr/bin/sh -c "readlink --canonicalize /etc/extensions/k3s.raw > /tmp/k3s-new"
                  ExecStartPost=/usr/bin/sh -c "if ! cmp --silent /tmp/k3s /tmp/k3s-new; then touch /run/reboot-required; fi"
                EOT
              }]
            },
          ] : u if var.os_family == "flatcar"],
        )
      }
    }) if local.uses_ignition
  }

  user_data = {
    for name, node in var.nodes : name => (
      local.uses_ignition ? base64encode(local.ignition_config[name]) : data.cloudinit_config.node[name].rendered
    )
  }
}
