# Security Policy

## Supported versions

Releases follow [semantic versioning](https://semver.org) and are listed on the
[Releases page](https://github.com/mbologna/k3s-oci/releases). Security fixes land on `main`
and ship in the next release; only the latest minor version is supported. Pin
`?ref=vX.Y.Z` and upgrade to the newest release to receive fixes.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

1. Go to the [Security tab](https://github.com/mbologna/k3s-oci/security) of this repository.
2. Click **"Report a vulnerability"** to open a private security advisory.
3. Describe the issue, steps to reproduce, and potential impact.

You can expect an acknowledgement within **48 hours** and a fix or mitigation plan within
**14 days** for confirmed vulnerabilities.

## Scope

In scope: the Terraform module, the node script (`files/`), the default GitOps applications
(`gitops/`), the scripts and the documentation; secrets leakage from Terraform state, user_data
or git history; network exposure of the cluster's API.

Out of scope: vulnerabilities in upstream projects (k3s, the operating systems, Longhorn, Argo CD,
Traefik, the OCI provider), which belong upstream.

## Known security trade-offs

- **Secrets in the node configuration.** Each node's script holds the k3s token, the server and
  client CA keys (`ca.tf`), the database password and, if set, the GitOps token. On opensuse it
  is the instance's user_data; on fcos and flatcar the user_data holds a pre-authenticated URL to
  it in the backups bucket. Anyone who can read the instance's metadata (OCI IAM `read
  instances`, or a process that reaches `169.254.169.254:80` on a node) can read it. Restrict
  instance read access in IAM; `gitops/network-policies/` keeps pods away from the metadata
  service (DNS to `169.254.169.254:53`, the VCN resolver, stays open). If a URL leaks, delete
  the pre-authenticated request; `tofu apply` creates a new one, which only new nodes use.
- **The Terraform state holds every cluster secret** (token, CA keys, database password). Keep
  it in an encrypted, access-controlled backend of its own; never commit it.
- **Admin kubeconfig.** The `kubeconfig` output is a `system:masters` client certificate valid
  for a year. Kubernetes cannot revoke a client certificate: a leaked one means replacing the
  client CA.
- **The database is reachable from every node** on 3306, as the k3s user that owns the cluster
  state.
