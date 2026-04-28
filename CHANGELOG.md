# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- Envoy Gateway (Gateway API) replaces Traefik as the ingress controller — `GatewayClass`, `Gateway`, `HTTPRoute`, `ClientTrafficPolicy`, `BackendTrafficPolicy`, `SecurityPolicy`
- External DNS support (`enable_external_dns`) — automatic DNS record management from Kubernetes service/ingress annotations
- External Secrets Operator (`enable_external_secrets`) — sync secrets from OCI Vault into Kubernetes `Secret` objects
- DNS-01 ACME challenge support in cert-manager `ClusterIssuer` (commented variants in `gitops/cert-manager/cluster-issuers.yaml`)
- `system-upgrade-controller` GitOps Application + upgrade Plans for automated k3s rolling upgrades (`gitops/system-upgrade/`)
- `gitops/cert-manager/application-template.yaml` — ArgoCD Application template for adopting ClusterIssuers into GitOps

### Changed
- Ingress: all `IngressRoute` resources replaced with `HTTPRoute`; Traefik `Middleware` replaced with `BackendTrafficPolicy`/`SecurityPolicy`
- ArgoCD rate limiting uses Envoy Gateway `BackendTrafficPolicy` instead of Traefik `RateLimit` middleware
- Longhorn UI BasicAuth uses Envoy Gateway `SecurityPolicy` instead of Traefik `Middleware`
- Network policies updated to `envoy-gateway-system` namespace (was `traefik`)

### Removed
- `ingress_controller` variable — Envoy Gateway is now the only supported ingress controller
- `traefik_chart_version` variable — **migration note below**

### Fixed
- `max_api_wait` and `max_attempts` were conflated in `k3s-install-agent.sh` (both were `10`; API wait is now correctly `60` seconds)
- Unquoted `$params_str` in k3s install invocations replaced with `"${install_params[@]}"` (word-splitting bug)
- `nfs-common` missing from server node apt packages (was present on agents only; required for Longhorn NFS mounts)
- `data.tf`: `local.public_lb_ip[0]` wrapped in `try()` to guard against momentarily-empty list during first apply
- `example/main.tf`: missing `region` and `public_key_path` wiring to module inputs
- `example/provider.tf`: `required_version` updated from `>= 1.5.0` to `>= 1.9.0`
- CI: added `permissions: {}` to all read-only jobs; renovate workflow has explicit write permissions

### Migration notes
- **`traefik_chart_version` removed**: if you have `traefik_chart_version = "..."` in your
  `terraform.tfvars`, remove that line before running `tofu apply`. Terraform will error on
  undeclared variable inputs.
- **`ingress_controller` removed**: remove `ingress_controller = "traefik2"` from any module
  call or `terraform.tfvars`. The variable no longer exists.
- **Envoy Gateway replaces Traefik**: existing `IngressRoute`, `Middleware`, and `TLSOption`
  resources will remain in cluster until manually deleted. Replace them with `HTTPRoute`,
  `BackendTrafficPolicy`, and `ClientTrafficPolicy` equivalents.

---

## [Pre-release — GitOps & observability hardening]

### Added
- `grafana_hostname` optional variable for Grafana UI HTTPRoute
- `grafana_admin_credentials` sensitive Terraform output
- Grafana admin password auto-generated via `random_password` (pre-created as K8s Secret in cloud-init)
- `PodDisruptionBudget` for argocd-server, argocd-repo-server, argocd-application-controller, cert-manager, cert-manager-webhook
- Longhorn `ServiceMonitor` for Prometheus scraping (`gitops/monitoring/longhorn-servicemonitor.yaml`)
- `AlertmanagerConfig` template with Slack/email/webhook options (`gitops/monitoring/alertmanager-config.yaml`)
- Longhorn OCI Object Storage backup target template (`gitops/longhorn/backup-target.yaml`)
- `gitops/update-repo-url.sh` helper script for updating repoURL after forking
- `SECURITY.md` with vulnerability disclosure policy and known trade-offs
- OCI Logging integration: log group, log, and Unified Agent configuration for cloud-init logs
- kube-prometheus-stack GitOps Application (minimal ARM64 configuration)
- Network policies extended to `argocd`, `monitoring`, `cert-manager`, `longhorn-system` namespaces
- `enable_oci_logging` variable (default: true)
- `argocd_initial_password_hint` Terraform output
- Renovate custom manager for `targetRevision:` in gitops YAML files
- OCI Vault (`enable_vault = true`) — cluster secrets stored in a software-protected DEFAULT-type OCI Vault; fetched at boot via instance_principal
- Boot volume backups (`enable_backup = true`) — weekly policy on all 4 node boot volumes; 1-week retention
- Object Storage state bucket (`enable_object_storage_state = true`) — versioned bucket, S3-compatible backend
- Longhorn backup bucket (`enable_longhorn_backup = true`) — versioned OCI Object Storage bucket; instructions in `longhorn_backup_setup` output
- OCI Notifications + Alertmanager webhook (`enable_notifications = false`) — opt-in; supports email subscription
- MySQL HeatWave (`enable_mysql = false`) — Always Free standalone DB in private subnet; credentials pre-created as K8s Secret
- Self-hosted Renovate workflow (`.github/workflows/renovate.yml`, daily 04:00 UTC)
- OpenTofu validate job in CI
- yamllint job for `gitops/` in CI
- Trivy IaC scan (HIGH/CRITICAL) in CI
- Resilience section in `gitops/README.md` with `topologySpreadConstraints` and PDB patterns for user workloads

### Changed
- Longhorn installation switched from `kubectl apply -f URL` to Helm (`longhorn/longhorn` chart) — atomic rollback, version-pinned, Renovate-tracked
- ArgoCD Helm install now uses `--atomic` (was `--wait` only)
- `boot_volume_size_in_gbs` max validation tightened from 200 → 50 GB (Always Free budget)
- `required_version` updated from `>= 1.5.0` to `>= 1.9.0`
- CI runners pinned to `ubuntu-24.04` (was `ubuntu-latest`)
- `wait_for_cluster_ready` error message now shows elapsed/total seconds with node status dump
- cert-manager installation switched from `kubectl apply` to Helm
- ArgoCD installation switched to Helm
- All Helm installs use `--atomic` for automatic rollback on failure
- CI workflow has path filters; tflint version pinned
- **Traefik ran as DaemonSet** — one pod per node, `system-cluster-critical` priority, resource requests set
- **Control-plane `NoSchedule` taints removed** after cluster init — all 4 nodes schedulable for user workloads
- Longhorn `defaultReplicaCount` and `persistence.defaultClassReplicaCount` explicitly pinned to `3`
- `enable_oci_logging` default changed `false` → `true`
- `notification_topic_endpoint` output marked `sensitive = true`
- CI `gitops/**` path added to workflow triggers

### Fixed
- Stale comment in `gitops/network-policies/default-deny.yaml`
- `pdbs.yaml` destination namespace clarified with comment

---

## [Pre-release — Traefik 2 & GitOps foundation]

### Added
- 3-node HA k3s cluster on `VM.Standard.A1.Flex` (4 OCPU / 24 GB total)
- 4th standalone worker instance via `k3s_standalone_worker`
- Private subnet for all nodes (no public IPs on compute)
- NAT Gateway for outbound traffic (free, 1 per VCN)
- Public Network Load Balancer (NLB) for HTTP/HTTPS ingress
- Internal Flexible Load Balancer for kubeapi HA
- Optional OCI Bastion Service (`enable_bastion`)
- Traefik 2 as ingress controller (DaemonSet, `system-cluster-critical`)
- cert-manager with Let's Encrypt ClusterIssuers (always installed)
- Longhorn distributed block storage (always installed)
- ArgoCD + Image Updater (always installed)
- kured for graceful kernel reboot management
- unattended-upgrades for automatic security patches
- k3s version resolved at plan-time from GitHub API
- `public_key` string variable with fallback to `public_key_path`
- `argocd_hostname` optional variable for IngressRoute + TLS cert
- Renovate configuration for automated dependency updates
- GitHub Actions CI: `terraform fmt`, `terraform validate`, ShellCheck
- GitOps App of Apps structure under `gitops/`
- Default-deny NetworkPolicy for default namespace
- Ubuntu 24.04 LTS only (no Oracle Linux)
- Cloud-init logging to `/var/log/k3s-cloud-init.log` + journald
- IMDSv2 standardised across all scripts
- Dynamic group scoped to cluster name (multi-cluster safe)
- `lifecycle { prevent_destroy = true }` on both load balancers
- `keepers` on `random_password.k3s_token` to prevent token churn
- `gitops/longhorn/ingress.yaml` for manual Longhorn IngressRoute management
- ClusterIssuers moved to `gitops/cert-manager/` (ArgoCD-managed)
- Network policies moved to pure GitOps (removed from cloud-init)

### Changed
- cert-manager installation switched from `kubectl apply` to Helm (`jetstack/cert-manager`)
- ArgoCD installation switched to Helm (`argo/argo-cd`, `server.insecure` via chart values)
- `wait_for_cluster_ready` now checks all nodes are `Ready` (not just any Running pod)
- CI workflow has path filters (only triggers on `.tf`, `files/`, `.github/` changes)
- tflint version pinned (was `latest`)
- `my_public_ip_cidr` description clarified (nodes are private; bastion required for SSH)

### Removed
- `region` variable (unused in root module; OCI provider gets region from provider config)
- `public_lb_shape` variable (unused)
- Inline `apply_network_policies()` in cloud-init (now managed via GitOps)
- Inline ClusterIssuer creation in cloud-init (now managed via GitOps)

### Migration notes
- **`argocd_release` renamed to `argocd_chart_release`**: update your `terraform.tfvars`.
  The value is now a Helm chart version (e.g. `7.8.23`) not a GitHub release tag (e.g. `v2.14.9`).
- **`region` removed from module inputs**: remove `region = ...` from any module call.
  The OCI provider reads the region from its own configuration.
- **`ingress_controller = "traefik"` no longer valid**: change to `"traefik2"` or remove
  the line entirely (the new default was `"traefik2"`).

