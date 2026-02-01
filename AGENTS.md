# AGENTS.md — guidance for AI coding agents

This file tells AI coding agents (GitHub Copilot, Codex, Claude, etc.) how to work
safely and effectively in this repository.

## Repository overview

Terraform module that deploys a production-ready [k3s](https://k3s.io) cluster on
[OCI Always Free](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
resources. All compute, networking, and storage must fit within the Always Free budget —
do not introduce resources that incur cost.

## Tech stack

| Layer | Technology |
|---|---|
| IaC | Terraform ≥ 1.9 / OpenTofu ≥ 1.9 |
| Cloud | Oracle Cloud Infrastructure (OCI) |
| OS | Ubuntu 24.04 LTS (aarch64) only |
| Kubernetes | k3s (latest resolved at plan time) |
| Ingress | Traefik 2 (`traefik2`) |
| Observability | kube-prometheus-stack (via GitOps) |
| Logging | OCI Unified Logging (optional) |
| Storage | Longhorn |
| GitOps | ArgoCD + Image Updater |
| TLS | cert-manager (Let's Encrypt) |
| Reboots | kured + unattended-upgrades |

## Always Free budget — hard constraints

| Resource | Free allowance | This module |
|---|---|---|
| A1.Flex compute | 4 OCPUs / 24 GB / 4 instances | 3 servers + 1 worker |
| Block storage | 200 GB | 4 × 50 GB boot volumes = 200 GB; bastion is OCI Bastion Service (managed, no VM, no storage) |
| NLB | 1 | 1 public NLB |
| Flex LB | 2 × 10 Mbps | 1 internal LB |
| E2.1.Micro | 2 | 0 (bastion uses OCI Bastion Service, not a VM) |
| NAT Gateway | 1 per VCN | 1 |

**Never add resources that exceed this budget.** If a change requires more OCPUs, storage,
or additional paid resources, flag it explicitly instead of implementing it.

## File map

```
vars.tf          — all input variables (add new vars here)
locals.tf        — derived locals (ssh_public_key, k3s_version, common_tags, agent_plugins)
data.tf          — cloud-init templatefile rendering, random_password (including longhorn_ui_password)
terraform.tf     — required_providers and version constraints
network.tf       — VCN, subnets, IGW, NAT GW, route tables
security.tf      — Security Lists
nsg.tf           — Network Security Groups
iam.tf           — Dynamic Group and Policy (scoped to cluster_name tag, includes log-content)
logging.tf       — OCI Log Group, Log, Unified Agent Configuration (enabled via enable_oci_logging)
compute.tf       — Instance pool (servers), pool (workers), standalone extra worker
lb.tf            — Internal Flexible LB (kubeapi HA)
nlb.tf           — Public Network LB (HTTP/HTTPS ingress)
output.tf        — Outputs (IPs, k3s_token, longhorn_ui_credentials, argocd_initial_password_hint, oci_log_group_id)
files/k3s-install-server.sh  — cloud-init for control-plane nodes (Ubuntu 24.04)
files/k3s-install-agent.sh   — cloud-init for worker nodes (Ubuntu 24.04)
gitops/apps/                 — ArgoCD Application manifests (App of Apps pattern)
gitops/network-policies/     — Default-deny NetworkPolicies (managed by network-policies.yaml App)
gitops/longhorn/             — Longhorn ingress with BasicAuth (Traefik Middleware + Secret)
gitops/cert-manager/         — ClusterIssuer templates + ArgoCD Application template (see adoption notes)
example/         — Example module usage
.github/workflows/terraform.yml  — CI: fmt, validate, tflint, ShellCheck, terraform-docs
.terraform-docs.yml          — terraform-docs config (inject mode; CI auto-commits README updates)
renovate.json    — Automated dependency updates
```

## Key conventions

### Terraform
- All resources get `freeform_tags = local.common_tags`.
- Versions in `vars.tf` use `# renovate:` inline comments so Renovate opens PRs automatically:
  ```hcl
  # renovate: datasource=github-releases depName=cert-manager/cert-manager
  default = "v1.16.3"
  ```
- Run `tofu fmt -recursive` (or `terraform fmt -recursive`) before committing — CI enforces it.
- `terraform validate` runs against both the root module and `example/` — keep both valid.
- The `lifecycle { prevent_destroy = true }` on both load balancers is intentional; do not remove it.
- **When renaming a resource**, always add a `moved {}` block so existing states don't require `terraform state mv`:
  ```hcl
  moved {
    from = oci_core_instance.old_name
    to   = oci_core_instance.new_name
  }
  ```
  Remove `moved {}` blocks only after all users have applied the change.

### Shell scripts (`files/`)
- Both scripts are **Terraform templatefiles**, not plain bash. `${var}` is a Terraform
  interpolation; `$${var}` is a literal `${var}` in the rendered script.
- The top-of-file `# shellcheck disable=...` comment is required for CI to pass — keep it.
- Ubuntu 24.04 only. No Oracle Linux, no multi-distro branches.
- Always use `set -euo pipefail` and the cloud-init log redirect at the top.

### Adding a new stack component
1. Add a version variable to `vars.tf` with a `# renovate:` comment.
2. Write an `install_<component>()` function in `k3s-install-server.sh`.
3. Call it inside the `if [[ "$IS_FIRST_SERVER" == "true" ]]; then` block.
4. Pass the version variable through the templatefile vars map in `data.tf`.

### GitOps
New Kubernetes manifests belong in `gitops/`. Add an ArgoCD `Application` CR in
`gitops/apps/` to have ArgoCD manage them automatically.

## CI checks (must pass before merging)

| Check | Command |
|---|---|
| Terraform format | `terraform fmt -check -recursive` |
| Terraform validate (root) | `terraform init -backend=false && terraform validate` |
| Terraform validate (example) | same, in `example/` |
| tflint | `tflint --config=.tflint.hcl` (pinned version, Renovate-managed) |
| ShellCheck | `shellcheck --severity=warning files/*.sh` |
| terraform-docs | auto-committed by CI if README drift detected |

Run all checks locally before pushing:
```bash
tofu fmt -recursive
tofu init -backend=false && tofu validate
(cd example && tofu init -backend=false && tofu validate)
tflint --config=.tflint.hcl
shellcheck --severity=warning files/k3s-install-server.sh files/k3s-install-agent.sh
terraform-docs .
```

## What NOT to do

- Do not add paid OCI resources (compute shapes other than A1.Flex, extra NLBs, etc.)
- Do not add Oracle Linux support — Ubuntu 24.04 LTS only
- Do not remove `lifecycle { prevent_destroy = true }` from load balancers
- Do not hardcode secrets, OCIDs, or credentials anywhere
- Do not remove the `# renovate:` comments on version variables
- Do not commit `example/terraform.tfvars` (it is gitignored; `.tfvars.example` is the template)
- Do not break the `terraform validate` step — templatefile vars must match what the scripts reference
- **`ingress_controller` only accepts `"traefik2"`** — do not add nginx or other ingress controllers
- **Do not add UFW or any iptables-front-end** to nodes. k3s manages iptables directly via flannel;
  adding ufw would flush k3s's rules on `ufw enable` and break pod networking. OCI NSGs provide
  the security boundary at the hypervisor level, independent of the OS firewall.
- **Do not add OCI Vault** — OCI Key Management / Vault is NOT an Always Free resource. Secrets
  (`k3s_token`, `longhorn_ui_password`, `grafana_admin_password`) are passed via cloud-init
  templatefile vars (stored in instance user-data). This is acceptable given the private subnet
  placement and OCI NSG boundary. Future improvement: switch to Vault when cost is acceptable.
- **Do not add an nginx stream proxy** back. The OCI NLB routes directly to Traefik NodePorts
  (`is_preserve_source = true` preserves real client IPs transparently). An extra nginx hop
  adds latency and complexity with no benefit.
- **Do not reduce `boot_volume_size_in_gbs` below 50 GB** — OCI requires ≥ 50 GB for boot
  volumes on all shapes (A1.Flex and E2.1.Micro alike). 4 × 50 GB = 200 GB exactly fills the
  Always Free block storage limit. Do not suggest 47 GB as an optimisation — it is not valid.

## Special implementation notes

### Longhorn UI BasicAuth
- Password is generated by `random_password.longhorn_ui_password` in `data.tf` and passed to
  cloud-init as `longhorn_ui_password`.
- The cloud-init script generates an APR1 hash: `openssl passwd -apr1 "$LONGHORN_PASSWORD"`
- A `Secret` (`longhorn-basic-auth`) and Traefik `Middleware` (`longhorn-basicauth`) are created
  in the `longhorn-system` namespace.
- `gitops/longhorn/ingress.yaml` references these for the Longhorn UI `IngressRoute`.
- Credentials are available via the `longhorn_ui_credentials` sensitive output.
- In heredocs where Terraform interpolation is needed (`<< LHEOF` not `<< 'LHEOF'`), Terraform
  vars use `${var}` and bash vars must use `$${VAR}`.

### cert-manager GitOps adoption
- Cloud-init bootstraps ClusterIssuers with the correct email from `var.letsencrypt_email`.
  This must happen at bootstrap time — the email cannot be in git without manual editing.
- `gitops/cert-manager/` contains template ClusterIssuers and an ArgoCD Application template.
- To enable ArgoCD management of ClusterIssuers: update the email in `cluster-issuers.yaml`,
  then copy `application-template.yaml` to `gitops/apps/cert-manager.yaml`.
- Do NOT place the template in `gitops/apps/` as-is — it contains `changeme@example.com`.

### OCI Logging (`logging.tf`)
- Controlled by `enable_oci_logging` variable (default: `true`).
- Creates: `oci_logging_log_group`, `oci_logging_log`, `oci_logging_unified_agent_configuration`.
- The dynamic group from `iam.tf` is referenced for the agent config.
- The `Custom Logs Monitoring` plugin is enabled in `locals.tf` `agent_plugins`.
- Ships `/var/log/k3s-cloud-init.log` to OCI Logging (10 GB/month free).
- `oci_log_group_id` output provides the OCID for use with `oci logging` CLI.

### terraform-docs
- README Variables and Outputs sections are auto-generated between `<!-- BEGIN_TF_DOCS -->`
  and `<!-- END_TF_DOCS -->` markers.
- CI (`terraform-docs` job) auto-commits README if the content drifts (git-push mode).
- Run `terraform-docs .` locally before pushing to avoid an extra CI commit.
- Config is in `.terraform-docs.yml` (inject mode, sort by name).
