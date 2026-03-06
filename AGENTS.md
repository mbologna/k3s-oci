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
| Object Storage | 20 GB | 2 versioned buckets — Terraform state (`enable_object_storage_state`) + Longhorn PVC backups (`enable_longhorn_backup`) |
| Vault (shared) | Software keys + 150 secrets | 3 secrets — k3s_token, longhorn_ui_password, grafana_admin_password (`enable_vault = true`) |
| Volume backups | 5 total | 4 — one per node, weekly, 1-week retention (`enable_backup = true`) |
| Notifications | 1M HTTPS + 3K email/month | 1 topic wired to Alertmanager (`enable_notifications = false`, opt-in) |
| MySQL HeatWave | 1 standalone, 50 GB | 1 DB system in private subnet (`enable_mysql = false`, opt-in) |

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
iam.tf           — Dynamic Group and Policy (scoped to cluster_name tag, includes log-content and secret-family)
logging.tf       — OCI Log Group, Log, Unified Agent Configuration (enabled via enable_oci_logging)
compute.tf       — Instance pool (servers), pool (workers), standalone extra worker
lb.tf            — Internal Flexible LB (kubeapi HA)
nlb.tf           — Public Network LB (HTTP/HTTPS ingress)
backup.tf        — Custom weekly backup policy + assignments for all node boot volumes (enable_backup)
vault.tf         — OCI Vault (DEFAULT type, SOFTWARE key), three cluster secrets (enable_vault)
objectstorage.tf — Versioned Object Storage bucket for Terraform state (enable_object_storage_state)
notifications.tf — OCI Notifications topic + optional email subscription (enable_notifications)
mysql.tf         — MySQL HeatWave DB system in private subnet (enable_mysql)
output.tf        — Outputs (IPs, k3s_token, longhorn_ui_credentials, argocd_initial_password_hint, oci_log_group_id, terraform_state_backend, notification_topic_endpoint, mysql_endpoint, vault_id)
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

### Reusability — fork pattern
Users who want to add their own apps on top of the built-in stack must fork this
repo. The workflow is:
1. Fork the repo on GitHub.
2. Run `bash gitops/update-repo-url.sh https://github.com/their-org/their-fork.git`
   to replace all `repoURL: https://github.com/mbologna/k3s-oci.git` occurrences in
   `gitops/apps/` with their fork URL. Commit and push.
3. Set `gitops_repo_url = "https://github.com/their-org/their-fork.git"` in
   `terraform.tfvars` so cloud-init writes the correct URL into `app-of-apps.yaml`.
4. Add their own ArgoCD `Application` manifests to `gitops/apps/` — each can point
   at any Helm registry or any Git repo; only the App of Apps manifest itself must
   live in the fork.

When helping users add apps, always remind them to run `update-repo-url.sh` and set
`gitops_repo_url` if they haven't already.

## CI checks (must pass before merging)

| Check | Command |
|---|---|
| Terraform format | `terraform fmt -check -recursive` |
| Terraform validate (root) | `terraform init -backend=false && terraform validate` |
| Terraform validate (example) | same, in `example/` |
| OpenTofu validate (root + example) | same as above but with `tofu` |
| tflint | `tflint --init && tflint --recursive` (pinned version, Renovate-managed; auto-discovers `.tflint.hcl`) |
| ShellCheck | `shellcheck --severity=warning files/*.sh` |
| YAML lint (gitops/ + .github/workflows/) | `yamllint -d '{extends: relaxed, rules: {line-length: {max: 200}}}' gitops/ .github/workflows/` |
| actionlint | `actionlint` (GitHub Actions workflow syntax) |
| Trivy IaC scan | `trivy config . --severity HIGH,CRITICAL` (Terraform + gitops) |
| terraform-docs | fails on diff in PRs; auto-committed on push to main |

Run all checks locally before pushing:
```bash
tofu fmt -recursive
tofu init -backend=false && tofu validate
(cd example && tofu init -backend=false && tofu validate)
tflint --init && tflint --recursive
shellcheck --severity=warning files/k3s-install-server.sh files/k3s-install-agent.sh
yamllint -d '{extends: relaxed, rules: {line-length: {max: 200}}}' gitops/ .github/workflows/
actionlint
trivy config . --severity HIGH,CRITICAL --skip-dirs .terraform,example/.terraform
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
- **Do not re-add `control-plane:NoSchedule` taints** — cloud-init removes these taints after cluster init so user workloads schedule across all 4 nodes. With only 1 worker, keeping the taints makes the worker a single point of failure for all workloads. All nodes are identically sized; etcd and user workloads coexist safely.
- **Do not add UFW or any iptables-front-end** to nodes. k3s manages iptables directly via flannel;
  adding ufw would flush k3s's rules on `ufw enable` and break pod networking. OCI NSGs provide
  the security boundary at the hypervisor level, independent of the OS firewall.
- **Vault uses `DEFAULT` type and `SOFTWARE` protection only** — `VIRTUAL_PRIVATE` vault type and `HSM` protection mode are NOT Always Free. `vault_type = "DEFAULT"` (shared vault) + `protection_mode = "SOFTWARE"` are entirely free. The 150-secret limit covers the three cluster secrets many times over. Never change the vault type or protection mode without verifying cost.
- **Do not add an nginx stream proxy** back. The OCI NLB routes directly to Traefik NodePorts
  (`is_preserve_source = true` preserves real client IPs transparently). An extra nginx hop
  adds latency and complexity with no benefit.
- **Do not reduce `boot_volume_size_in_gbs` below 50 GB** — OCI requires ≥ 50 GB for boot
  volumes on all shapes (A1.Flex and E2.1.Micro alike). 4 × 50 GB = 200 GB exactly fills the
  Always Free block storage limit. Do not suggest 47 GB as an optimisation — it is not valid.

## Special implementation notes

### Traefik ingress
- Deployed as a **DaemonSet** (one pod per node) so every NLB backend serves ingress locally — no cross-node forwarding hop, no single-pod SPOF.
- `priorityClassName: system-cluster-critical` ensures Traefik pods preempt user workloads under memory pressure and are never evicted before system daemons.
- `resources.requests: 100m CPU / 128Mi RAM` prevents scheduling on nodes that cannot sustain ingress load.
- `PodDisruptionBudget maxUnavailable: 1` (`traefik-pdb`) is applied immediately after Helm install so kured/drain can only take down one Traefik pod at a time — 3 of 4 nodes always serve ingress during rolling maintenance.
- Do not change `deployment.kind` back to `Deployment` — this would reintroduce a single-pod SPOF for all HTTP/HTTPS traffic.

### Longhorn storage
- Replica count is **explicitly pinned to 3** via `--set defaultSettings.defaultReplicaCount=3` and `--set persistence.defaultClassReplicaCount=3` in the Helm install. Do not rely on the upstream chart default.
- With 4 nodes and 3 replicas, any single node can be lost without PVC data loss.
- The etcd HA ceiling applies independently: losing 2 control-plane nodes loses etcd quorum regardless of Longhorn replica count.

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

### OCI Vault (`vault.tf`)
- Controlled by `enable_vault` variable (default: `true`).
- Uses `vault_type = "DEFAULT"` (shared vault, free). `VIRTUAL_PRIVATE` vaults cost money — never use that type.
- Key uses `protection_mode = "SOFTWARE"` (free). HSM-protected keys are NOT free.
- Stores three secrets: `k3s_token`, `longhorn_ui_password`, `grafana_admin_password`.
- Cloud-init fetches secrets at boot via `oci secrets secret-bundle get-secret-bundle` with `OCI_CLI_AUTH=instance_principal`.
- When `enable_vault = false`, the plaintext values are passed through cloud-init templatefile vars (fallback for the `%{ else }` branches in the scripts).
- The IAM policy uses `concat()` to add `read secret-family` only when `enable_vault = true`.
- Agent script (`k3s-install-agent.sh`) also installs OCI CLI and fetches k3s_token from Vault when enabled.

### Boot Volume Backups (`backup.tf`)
- Controlled by `enable_backup` variable (default: `true`).
- Creates a custom `oci_core_volume_backup_policy` with weekly full backups, 1-week retention.
- Assigns the policy to all server boot volumes (`data.oci_core_instance.k3s_servers[*].boot_volume_id`) and the standalone worker boot volume.
- With 4 nodes and 1-week retention there are at most 4 active backups — within the 5-backup Always Free limit.
- Do NOT increase retention or frequency beyond 1-week/weekly without exceeding the free limit.

### Object Storage Buckets (`objectstorage.tf`)
- `data.oci_objectstorage_namespace.k3s` is created when **either** `enable_object_storage_state` or `enable_longhorn_backup` is true — both buckets share it.
- **Terraform state bucket** (`enable_object_storage_state = true`): versioned, `NoPublicAccess`, name `${cluster_name}-terraform-state`. S3-compatible endpoint and bucket name in `terraform_state_backend` output.
- **Longhorn backup bucket** (`enable_longhorn_backup = true`): versioned, `NoPublicAccess`, name `${cluster_name}-longhorn-backup`. The `longhorn_backup_setup` output prints the three steps to connect Longhorn (Customer Secret Key → kubectl secret → uncomment `gitops/longhorn/backup-target.yaml`).
- Both buckets share the 20 GB Always Free Object Storage allowance. Longhorn backup bucket uses no versioning for actual backup blobs (Longhorn manages its own retention), but the bucket resource has versioning enabled for accidental-delete protection.
- Users need OCI Customer Secret Keys (S3 credentials) to use either bucket — these are user-created in the Console and not managed by Terraform.

### OCI Notifications + Alertmanager (`notifications.tf`)
- Controlled by `enable_notifications` variable (default: `false`).
- Creates `oci_ons_notification_topic.k3s_alerts` + optional email subscription (`alertmanager_email`).
- Cloud-init **always** creates the `alertmanager-oci-config` Secret in the `monitoring` namespace — with a null receiver when disabled, OCI webhook receiver when enabled.
- `gitops/apps/kube-prometheus-stack.yaml` references this secret via `alertmanager.alertmanagerSpec.configSecret`. Do NOT remove `configSecret: alertmanager-oci-config` from that file — the secret always exists.
- `notification_topic_endpoint` output provides the HTTPS endpoint for the Alertmanager webhook.

### MySQL HeatWave (`mysql.tf`)
- Controlled by `enable_mysql` variable (default: `false`).
- Uses `shape_name = var.mysql_shape` (default `"MySQL.Free"` — the Always Free shape).
- Placed in the private subnet, reachable by all k3s nodes on port 3306.
- Admin password generated by `random_password.mysql_admin_password` (in `mysql.tf`).
- Cloud-init pre-creates a `mysql-credentials` Kubernetes Secret in the `default` namespace.
- `mysql_endpoint` and `mysql_admin_credentials` (sensitive) outputs are available after apply.
- `is_highly_available = false` — HA MySQL is NOT Always Free.
