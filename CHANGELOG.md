# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- Initial release derived from OCI Always Free resource analysis
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
