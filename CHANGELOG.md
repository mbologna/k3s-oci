# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- `grafana_hostname` optional variable for Grafana IngressRoute
- `grafana_admin_credentials` sensitive Terraform output
- Grafana admin password auto-generated via `random_password` (pre-created as K8s Secret in cloud-init)
- Traefik `RateLimit` middleware (50 rps, burst 100) for ArgoCD UI
- `PodDisruptionBudget` for argocd-server, argocd-repo-server, argocd-application-controller, cert-manager, cert-manager-webhook
- `PodDisruptionBudget maxUnavailable: 1` for Traefik DaemonSet (`traefik-pdb`) — limits kured/drain to one Traefik pod at a time; 3 of 4 nodes always serve ingress
- Longhorn `ServiceMonitor` for Prometheus scraping (`gitops/monitoring/longhorn-servicemonitor.yaml`)
- `AlertmanagerConfig` template with Slack/email/webhook options (`gitops/monitoring/alertmanager-config.yaml`)
- HTTP→HTTPS redirect via Traefik `RedirectScheme` middleware + low-priority catch-all IngressRoute (`gitops/traefik/redirect.yaml`)
- Longhorn OCI Object Storage backup target template (`gitops/longhorn/backup-target.yaml`)
- `gitops/update-repo-url.sh` helper script for updating repoURL after forking
- `SECURITY.md` with vulnerability disclosure policy and known trade-offs
- OCI Logging integration: log group, log, and Unified Agent configuration for cloud-init logs
- kube-prometheus-stack GitOps Application (minimal ARM64 configuration)
- Network policies extended to `argocd`, `monitoring`, `cert-manager`, `longhorn-system` namespaces
- `enable_oci_logging` variable (default: true)
- `argocd_initial_password_hint` Terraform output
- Longhorn UI BasicAuth via Traefik Middleware
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
- All IngressRoutes (ArgoCD, Longhorn, Grafana) now reference `tls-modern` TLSOption (TLS 1.2+, strong ciphers, sniStrict)
- `boot_volume_size_in_gbs` max validation tightened from 200 → 50 GB (Always Free budget)
- `required_version` updated from `>= 1.5.0` to `>= 1.9.0` (module uses validation blocks, `startswith()`, etc.)
- CI runners pinned to `ubuntu-24.04` (was `ubuntu-latest`)
- `wait_for_cluster_ready` error message now shows elapsed/total seconds with node status dump
- `ingress_controller` now only accepts `traefik2`; built-in k3s Traefik option removed
- cert-manager installation switched from `kubectl apply` to Helm
- ArgoCD installation switched to Helm
- All Helm installs use `--atomic` for automatic rollback on failure
- CI workflow has path filters; tflint version pinned
- **Traefik now runs as DaemonSet** (was single-replica Deployment) — one pod per node eliminates ingress SPOF and removes cross-node forwarding hops
- Traefik `priorityClassName` set to `system-cluster-critical` — never evicted under memory pressure
- Traefik resource requests set (`100m` CPU / `128Mi` RAM)
- **Control-plane `NoSchedule` taints removed** after cluster init — all 4 nodes schedulable for user workloads; single worker is no longer a workload SPOF
- Longhorn `defaultReplicaCount` and `persistence.defaultClassReplicaCount` explicitly pinned to `3` in Helm values
- `enable_oci_logging` default changed `false` → `true`
- `notification_topic_endpoint` output marked `sensitive = true`
- CI `gitops/**` path added to workflow triggers

### Fixed
- Stale comment in `gitops/network-policies/default-deny.yaml`
- `pdbs.yaml` destination namespace clarified with comment


- `gitops/longhorn/ingress.yaml` for manual Longhorn IngressRoute management
- `argocd_initial_password_hint` Terraform output
- Longhorn UI BasicAuth via Traefik Middleware
- kube-prometheus-stack GitOps Application (minimal ARM64 configuration)
- OCI Logging integration: log group, log, and Unified Agent configuration for cloud-init logs
- ClusterIssuers moved to `gitops/cert-manager/` (ArgoCD-managed)
- Network policies moved to pure GitOps (removed from cloud-init)

### Changed
- `ingress_controller` now only accepts `traefik2`; built-in k3s Traefik option removed
- `ingress_controller` default changed from `traefik` to `traefik2`
- cert-manager installation switched from `kubectl apply` to Helm (`jetstack/cert-manager`)
- ArgoCD installation switched to Helm (`argo/argo-cd`, `server.insecure` via chart values)
- All Helm installs now use `--atomic` for automatic rollback on failure
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
  the line entirely (the new default is `"traefik2"`).


- 3-node HA k3s cluster on `VM.Standard.A1.Flex` (4 OCPU / 24 GB total)
- 4th standalone worker instance via `k3s_standalone_worker`
- Private subnet for all nodes (no public IPs on compute)
- NAT Gateway for outbound traffic (free, 1 per VCN)
- Public Network Load Balancer (NLB) for HTTP/HTTPS ingress
- Internal Flexible Load Balancer for kubeapi HA
- Optional E2.1.Micro bastion host
- Traefik 2 as the only supported ingress controller
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
- Ubuntu 22.04 LTS only (no Oracle Linux)
- Cloud-init logging to `/var/log/k3s-cloud-init.log` + journald
- IMDSv2 standardised across all scripts
- Dynamic group scoped to cluster name (multi-cluster safe)
- `lifecycle { prevent_destroy = true }` on both load balancers
- `keepers` on `random_password.k3s_token` to prevent token churn
