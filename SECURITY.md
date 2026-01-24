# Security Policy

## Supported versions

Only the latest commit on `main` is actively maintained. There are no versioned releases.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

If you discover a security issue in this project (Terraform module, cloud-init scripts,
GitOps manifests, or documentation), please disclose it privately:

1. Go to the [Security tab](https://github.com/mbologna/k3s-oci/security) of this repository.
2. Click **"Report a vulnerability"** to open a private security advisory.
3. Describe the issue, steps to reproduce, and potential impact.

You can expect an acknowledgement within **48 hours** and a fix or mitigation plan within
**14 days** for confirmed vulnerabilities.

## Scope

Issues in scope:
- Privilege escalation or lateral movement via the deployed k3s cluster
- Secrets leakage from Terraform state, cloud-init user-data, or git history
- OCI IAM policy misconfigurations allowing unintended access
- Supply-chain issues in pinned versions or Renovate configuration

Out of scope:
- Vulnerabilities in upstream projects (k3s, Longhorn, ArgoCD, Traefik, cert-manager) —
  please report those to the respective upstream projects
- Issues requiring physical access to OCI infrastructure
- Best-practice suggestions (open a regular issue instead)

## Known security trade-offs

- **Secrets in cloud-init user-data**: `k3s_token`, `longhorn_ui_password`, and
  `grafana_admin_password` are passed via Terraform templatefile and land in OCI instance
  user-data (accessible via IMDSv2 from within the instance). This is an accepted trade-off
  for the Always Free tier, which precludes OCI Vault (not an Always Free resource).
  Nodes live in a private subnet protected by OCI NSGs.
- **Self-signed bootstrap CA**: k3s generates its own cluster CA at bootstrap time.
  Rotate it if the cluster is long-lived and you require compliance with your CA policy.
