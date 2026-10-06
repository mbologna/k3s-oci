# Security Policy

## Supported versions

Releases follow [semantic versioning](https://semver.org) and are listed on the
[Releases page](https://github.com/mbologna/k3s-oci/releases). Security fixes land on `main`
and ship in the next release; only the latest minor version is supported — pin
`?ref=vX.Y.Z` and upgrade to the newest release to receive fixes.

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
- Vulnerabilities in upstream projects (k3s, Longhorn, ArgoCD, Envoy Gateway, cert-manager) —
  please report those to the respective upstream projects
- Issues requiring physical access to OCI infrastructure
- Best-practice suggestions (open a regular issue instead)

## Known security trade-offs

- **Secrets in cloud-init user-data**: `k3s_token` and `longhorn_ui_password`
  are passed via Terraform templatefile and land in OCI instance
  user-data (accessible via IMDSv2 from within the instance). **Mitigation:** set
  `enable_vault = true` to store secrets in an OCI Vault (DEFAULT type, software-protected,
  Always Free) and have nodes fetch them at boot via instance_principal — secrets are never
  embedded in user-data. With `enable_vault = false` (the default is `true`), the trade-off is accepted
  given the private-subnet placement and OCI NSG boundary.
- **Self-signed bootstrap CA**: k3s generates its own cluster CA at bootstrap time.
  Rotate it if the cluster is long-lived and you require compliance with your CA policy.
