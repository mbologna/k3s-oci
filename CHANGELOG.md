# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Removed

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
