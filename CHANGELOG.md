# Changelog

All notable changes to this project will be documented in this file.

## [1.1.1](https://github.com/mbologna/k3s-oci/compare/v1.1.0...v1.1.1) (2026-10-10)


### Bug Fixes

* **ci:** repin reusable workflows to current .github HEAD ([ed60246](https://github.com/mbologna/k3s-oci/commit/ed6024684195618b4797eb1a2d13a8bdb30bec4f))
* **kured:** wait for k3s upgrades and schedule reboots in UTC ([d71c33f](https://github.com/mbologna/k3s-oci/commit/d71c33f9d17283044e6ad17e292bd432e448d84f))

## [1.1.0](https://github.com/mbologna/k3s-oci/compare/v1.0.1...v1.1.0) (2026-10-07)


### Features

* allow seeding the k3s cluster ca from oci vault ([253d616](https://github.com/mbologna/k3s-oci/commit/253d6167e0fdbb47f2d02bca8b1c79f170b7e964))
* **example:** pass k3s_ca_vault_secret_id through ([9ff9541](https://github.com/mbologna/k3s-oci/commit/9ff95412304959fc66d9c1103cb943e730c3576d))

## [1.0.1](https://github.com/mbologna/k3s-oci/compare/v1.0.0...v1.0.1) (2026-10-06)


### Bug Fixes

* **deps:** accept oci provider 8.x and 9.x in the module ([b5e0c6a](https://github.com/mbologna/k3s-oci/commit/b5e0c6a4f37914c68c46182bd3af0934441c1b0f))
* install gateway api v1.6.1 crds, matching envoy gateway v1.9.2 ([dc0b0d3](https://github.com/mbologna/k3s-oci/commit/dc0b0d33a63f73fa867239771d9f0dd910f12ea6))

## [1.0.0](https://github.com/mbologna/k3s-oci/releases/tag/v1.0.0) (2026-10-06)

First tagged release. Pin it with `source = "github.com/mbologna/k3s-oci?ref=v1.0.0"`.
It covers everything up to this point: the 1 server + 1 worker Always Free topology on
Ubuntu 26.04, Envoy Gateway, Longhorn with Object Storage backups, ArgoCD, cert-manager,
OCI Vault, etcd snapshots and the keep-data rebuild path. Later releases are cut by
release-please from conventional commits.

### Fixed

- **ESO was installed even with `enable_external_secrets = false`**: `gitops/apps/external-secrets.yaml`
  duplicated `gitops/optional/external-secrets.yaml`. The optional copy is now the only one,
  so ESO is deployed only through the `optional-external-secrets` wrapper.
- **`network-policies` could not sync on clusters without the optional features**: the
  `external-dns` / `external-secrets` namespaces were never created (`CreateNamespace` only
  covers the destination namespace). `gitops/network-policies/namespaces.yaml` now creates them.
- **`example/` pinned stale chart versions** (gateway-api, cert-manager, ArgoCD, ESO) that
  overrode the module's Renovate-tracked defaults. Remove these four variables from your
  example-based `terraform.tfvars` if you copied them.
- **`just kubeconfig` / `just ssh` failed from the repo root**; `ssh-node.sh` now also works
  with `expose_ssh = true` (no bastion) and matches the 1 server + 1 worker topology.
- `gitops/update-repo-url.sh` also rewrites the `*/application-template.yaml` files.
- `scripts/setup-longhorn-backup.sh` warns against admin-user keys and applies the
  `daily-backup` RecurringJob instead of printing a non-working `BackupVolume` example.

- **`gitops_https_token` / `gitops_ssh_private_key` were stored in Vault without base64
  encoding** while the secret was declared `content_type = "BASE64"`. cloud-init's
  `fetch_from_vault()` base64-decodes every secret, so an HTTPS token arrived as garbage
  and ArgoCD could not clone the repo. Both are now wrapped in `base64encode()` like the
  other secrets. If you worked around this by passing a pre-encoded SSH key, pass the raw
  PEM/OpenSSH key instead (the stored secret content stays identical).

### Removed

- **Ubuntu 24.04 support dropped — nodes now run Ubuntu 26.04 LTS.** The image data source
  is pinned to `operating_system_version = "26.04"` and the short-lived `ubuntu_version`
  variable is removed (drop it from your module block). Existing nodes keep their image
  (`ignore_changes`); only rebuilt instances move to 26.04.
- **Monitoring stack removed entirely** (kube-prometheus-stack: Prometheus + Grafana +
  Alertmanager, plus the OCI Notifications/Alertmanager integration). The module no longer
  deploys any metrics/dashboards/alerting stack — gatus-style external uptime checks and
  targeted node/Longhorn alerts are expected to be provided out-of-band. Removed:
  - `gitops/apps/kube-prometheus-stack.yaml`, `gitops/apps/monitoring-extras.yaml`,
    `gitops/monitoring/`, `gitops/network-policies/monitoring.yaml`, and the monitoring PDBs
    (grafana/alertmanager/kube-state-metrics) from `gitops/pdbs/pod-disruption-budgets.yaml`.
  - `notifications.tf` and the `enable_notifications` / `alertmanager_email` variables, the
    `notification_topic_endpoint` output, and the `alertmanager-oci-config` secret.
  - `var.grafana_hostname`, the `grafana_admin_credentials` output, the
    `grafana_admin_password` Vault secret, and all `configure_grafana_ingress` cloud-init logic.
  - The `--etcd-expose-metrics` k3s server flag and the `servers_allow_etcd_metrics` NSG rule
    (TCP 2381), which existed solely for in-cluster Prometheus scraping.
  - cert-manager's ServiceMonitor is now disabled (`servicemonitor.enabled=false`) since the
    Prometheus operator CRDs are no longer installed.

### Added

- **Resource limits for cert-manager components** (`gitops/apps/cert-manager.yaml`):
  Added `resources.requests` and `limits` for the controller, webhook, cainjector, and
  startupapicheck. On a 6 GB RAM A1.Flex node running etcd + k3s + user workloads,
  unbounded cert-manager pods can cause OOM events under memory pressure.

### Fixed

- **`k3s-server.sh`: hardcoded `:6443` in join command** (`files/lib/k3s-server.sh`):
  The `install_k3s_server()` join branch was using `"https://${K3S_URL}:6443"` instead of
  `"https://${K3S_URL}:${KUBE_API_PORT:-6443}"`. This bug was previously fixed in
  `wait_for_kubeapi()` but missed in the actual `curl -sfL https://get.k3s.io | sh`
  join invocation. Non-default `kube_api_port` values would silently fall back to 6443
  when a server tried to join the existing cluster.

- **`external-dns`: `domainFilters`, `zoneIdFilters`, `txtOwnerId` never injected**
  (`files/lib/k3s-argocd.sh`, `gitops/optional/external-dns.yaml`):
  `EXTERNAL_DNS_DOMAIN_FILTER` was exported to cloud-init (and required by `checks.tf`) but
  never actually passed to the external-dns Helm release. `CLOUDFLARE_ZONE_ID` and
  `CLUSTER_NAME` were also absent from the Helm values, meaning external-dns would manage ALL
  zones the token had access to, with a hardcoded `txtOwnerId: k3s-cluster` that would conflict
  in multi-cluster setups.
  
  Fixed by replacing the `create_optional_app "external-dns"` call with a new
  `create_external_dns_app()` function that creates the ArgoCD Application inline (similar to
  how `install_argocd` creates the App of Apps) with the correct runtime values:
  - `domainFilters: [${EXTERNAL_DNS_DOMAIN_FILTER}]`
  - `zoneIdFilters: [${CLOUDFLARE_ZONE_ID}]`
  - `txtOwnerId: ${CLUSTER_NAME}`
  
  `gitops/optional/external-dns.yaml` is now a reference template only (marked clearly with a
  header comment). Added a `# renovate:` comment to `create_external_dns_app()` so Renovate
  opens PRs when a new chart version is published. Updated `renovate.json` with a custom manager
  to parse the shell function's `local chart_version=` pattern.

### Changed

- **CI trigger paths** (`.github/workflows/ci.yml`): Added `CHANGELOG.md`, `AGENTS.md`,
  and `Justfile` to both the `push` and `pull_request` path filters so CI runs when these
  files are modified.

- **`AGENTS.md`**: Updated External DNS section — removed the manual `txtOwnerId` update
  instruction (now automatic from `var.cluster_name`) and documented that
  `gitops/optional/external-dns.yaml` is a reference template only.

### Added

- **Always Free budget `check {}` blocks** (`checks.tf`): Four new Terraform 1.9+ check blocks
  guard against accidentally exceeding Always Free limits at plan time:
  - `always_free_ocpu_budget`: total OCPUs across all nodes must be ≤ 4.
  - `always_free_ram_budget`: total RAM across all nodes must be ≤ 24 GB.
  - `always_free_node_count`: total node count must be ≤ 4.
  - `expose_ssh_makes_bastion_redundant`: warns when both `expose_ssh` and `enable_bastion`
    are true (bastion becomes redundant, delays destroy due to OCI VNIC cleanup).

- **Cloudflare API token stored in OCI Vault** (`vault.tf`, `data.tf`, `files/lib/k3s-secrets.sh`):
  When `enable_vault = true` and `cloudflare_api_token` is set, the token is now stored as a
  Vault secret (`${cluster_name}-cloudflare-api-token`) and fetched at bootstrap time via
  `oci secrets secret-bundle get`. Plain-text `CLOUDFLARE_API_TOKEN` is no longer present in
  instance user-data when vault is enabled.

- **`KUBE_API_PORT` exported to cloud-init** (`locals.tf`, `files/server-vars.sh.tpl`,
  `files/agent-vars.sh.tpl`): The `kube_api_port` variable is now passed to both server and
  agent cloud-init scripts. `wait_for_kubeapi()` in `k3s-server.sh` and the agent wait loop in
  `k3s-agent.sh` now honour `${KUBE_API_PORT:-6443}` instead of hardcoding `:6443`.

- **Agent diagnostic output** (`files/lib/k3s-agent.sh`): The agent wait loop now prints a
  diagnostic `curl` status every 30 attempts to make cloud-init log tailing more informative
  when the API server is slow to come up.

- **Optional `route_name` parameter for `configure_app_ingress()`**
  (`files/lib/k3s-argocd.sh`): A 6th optional parameter lets callers specify the HTTPRoute
  resource name independently from the backend service name, for apps whose gitops HTTPRoute
  file uses a different name from the backend service.

- **Resource requests/limits for Envoy proxy pods** (`gitops/gateway/envoy-proxy.yaml`):
  Added `resources.requests: {cpu: 100m, memory: 128Mi}` and `limits: {memory: 256Mi}`
  under the `envoyDaemonSet.patch` spec to prevent OOMKill of ingress under load.

- **Resource requests/limits for kured** (`gitops/apps/kured.yaml`): Added
  `resources.requests: {cpu: 10m, memory: 32Mi}` and `limits: {memory: 64Mi}`.

- **Resource requests/limits for ArgoCD controllers** (`gitops/apps/argocd.yaml`): Added
  resource boundaries for `applicationController`, `redis`, and `notifications` components.

- **Resource requests/limits for ArgoCD Image Updater** (`gitops/apps/argocd-image-updater.yaml`):
  Added `resources.requests: {cpu: 10m, memory: 32Mi}` and `limits: {memory: 64Mi}`.
  Added usage documentation comments to the Application manifest.

- **NetworkPolicies for optional namespaces** (`gitops/network-policies/external-dns.yaml`,
  `gitops/network-policies/external-secrets.yaml`): Default-deny + allow egress policies for
  `external-dns` and `external-secrets` namespaces, pre-applied by the `network-policies`
  ArgoCD app (now uses `CreateNamespace=true`).

- **Version pinning comments in system-upgrade Plans** (`gitops/system-upgrade/plans.yaml`):
  Added commented `version:` field with `# renovate:` annotation so users can easily switch
  from channel-based to version-pinned upgrades and get Renovate PRs automatically.

- **`tflint`, `trivy`, `docs` recipes in `Justfile`**: `just ci` now runs all six CI checks
  (`fmt`, `validate`, `shellcheck`, `yamllint`, `tflint`, `trivy`). `just validate` now
  runs `tofu init -backend=false` first to avoid stale provider lock errors.

- **Thematic locals for server cloud-init vars** (`data.tf`): Replaced a 38-key flat inline
  `merge({...})` in the `templatefile()` call with named locals grouped by concern
  (`_server_identity_vars`, `_server_gitops_vars`, `_server_bootstrap_vars`,
  `_server_secret_vars`, `_server_feature_vars`, `_server_optional_vars`,
  `_server_hostname_vars`, `_server_debug_vars`, `k3s_server_cloud_init_vars`).

### Fixed

- **`backup_count_within_free_limit` check** (`checks.tf`): The condition was incorrectly
  adding `k3s_worker_pool_size` to the backup count. `backup.tf` assigns policies only to
  server pool instances and the standalone worker — not to pool workers. Fixed.

- **Journald config idempotency** (`files/lib/common.sh`): Replaced `echo >> /etc/systemd/journald.conf`
  (append, not idempotent) with a proper drop-in at
  `/etc/systemd/journald.conf.d/10-k3s-size-limit.conf`. Re-running cloud-init or re-imaging
  a node no longer appends duplicate entries.

- **Removed `python3-pip` from bootstrap packages** (`files/lib/common.sh`): OCI CLI is
  installed from the official install script, not via pip. `python3-pip` was unused,
  wasted ~50 MB, and triggered an unnecessary apt warning on Ubuntu 24.04.

- **Removed duplicate `apt-get update`** (`files/lib/common.sh`): `configure_unattended_upgrades()`
  was calling `apt-get update` redundantly after `bootstrap()` had already run it.

### Changed

- **`network-policies` ArgoCD app** (`gitops/apps/network-policies.yaml`): Changed
  `CreateNamespace=false` → `CreateNamespace=true` so the app can pre-create
  `external-dns` and `external-secrets` namespaces for the new NetworkPolicy files.

### Documentation

- Updated `AGENTS.md` to document the optional 6th `[route_name]` parameter in
  `configure_app_ingress()`.
