# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- `longhorn_hostname`, `gitops_repo_url` optional variables
- `kured_start_time`, `kured_end_time`, `kured_reboot_days` variables for maintenance window
- `oci_cli_version` variable with Renovate tracking
- `argocd_chart_release` variable (Helm chart version, replaces `argocd_release`)
- tflint in CI (`.tflint.hcl` + `terraform-linters/setup-tflint` action)
- Renovate GitHub Actions manager with digest pinning
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
- 4th standalone worker instance via `k3s_extra_worker_node`
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
