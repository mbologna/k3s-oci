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
| Ingress | Envoy Gateway (Gateway API) |
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
| Vault (shared) | Software keys + 150 secrets | 3–5 secrets — k3s_token, longhorn_ui_password, grafana_admin_password (`enable_vault = true`); +2 Tailscale OAuth (`enable_tailscale = true`) |
| Volume backups | 5 total | 4 — one per node, weekly, 1-week retention (`enable_backup = true`) |
| Notifications | 1M HTTPS + 3K email/month | 1 topic wired to Alertmanager (`enable_notifications = false`, opt-in) |
| MySQL HeatWave | 1 standalone, 50 GB | 1 DB system in private subnet (`enable_mysql = false`, opt-in) |

**Never add resources that exceed this budget.** If a change requires more OCPUs, storage,
or additional paid resources, flag it explicitly instead of implementing it.

## File map

```
vars.tf          — all input variables (add new vars here)
locals.tf        — derived locals (ssh_public_key, k3s_version, common_tags, agent_plugins, kubeconfig hints)
data.tf          — cloud-init assembly (join of vars tpl + lib files), random_password resources
versions.tf      — required_providers and version constraints
checks.tf        — Terraform check{} blocks: feature flag co-dependency validation (requires Terraform ≥ 1.9)
moved.tf         — moved{} blocks for in-flight resource renames; cleared after one release
network.tf       — VCN, subnets, IGW, NAT GW, route tables
security.tf      — Security Lists
nsg.tf           — Network Security Groups
iam.tf           — Dynamic Group and Policy (scoped to cluster_name tag, includes log-content and secret-family)
logging.tf       — OCI Log Group, Log, Unified Agent Configuration (enabled via enable_oci_logging)
compute.tf       — Instance pool (servers), pool (workers), standalone extra worker
lb.tf            — Internal Flexible LB (kubeapi HA)
nlb.tf           — Public Network LB (HTTP/HTTPS ingress); backend sets/listeners use for_each over nlb_web_protocols local
backup.tf        — Custom weekly backup policy + assignments for all node boot volumes (enable_backup)
vault.tf         — OCI Vault (DEFAULT type, SOFTWARE key), 3–5 cluster secrets: k3s_token, longhorn_ui_password, grafana_admin_password; +tailscale OAuth pair when enable_tailscale = true
objectstorage.tf — Versioned Object Storage bucket for Terraform state (enable_object_storage_state)
notifications.tf — OCI Notifications topic + optional email subscription (enable_notifications)
mysql.tf         — MySQL HeatWave DB system in private subnet (enable_mysql)
output.tf        — Outputs (IPs, k3s_token, longhorn_ui_credentials, argocd_initial_password_hint, oci_log_group_id, terraform_state_backend, notification_topic_endpoint, mysql_endpoint, vault_id, tailscale_vault_secret_names)
files/server-vars.sh.tpl          — cloud-init header for servers: ONLY file with Terraform ${var} syntax
files/agent-vars.sh.tpl           — cloud-init header for agents: ONLY file with Terraform ${var} syntax
files/kubeconfig-hint-bastion.tpl     — kubeconfig retrieval instructions when bastion is enabled
files/kubeconfig-hint-no-bastion.tpl  — kubeconfig retrieval instructions when bastion is disabled
files/lib/common.sh               — pure bash: OS-agnostic helpers: setup_shared_ssh_host_key(), configure_longhorn_prereqs(), install_oci_cli(), install_helm(), resolve_flannel_params()
files/lib/bootstrap-ubuntu.sh    — pure bash: Ubuntu bootstrap: wait_apt_lock(), bootstrap(), configure_unattended_upgrades() (apt, unattended-upgrades, needrestart)
files/lib/bootstrap-opensuse.sh  — pure bash: openSUSE bootstrap: bootstrap(), configure_unattended_upgrades() (zypper, /usr/local/sbin/zypper-patch-with-sentinel, kured sentinel)
files/lib/k3s-server.sh           — pure bash: first-server election, k3s install, main entry point
files/lib/k3s-bootstrap.sh        — pure bash: orchestrator — calls install_gateway_api_crds() then run_bootstrap()
files/lib/k3s-secrets.sh          — pure bash: pre_create_secrets() — Longhorn, Grafana, Alertmanager, MySQL, Cloudflare secrets
files/lib/k3s-cert-manager.sh     — pure bash: install_certmanager() — cert-manager Helm + ClusterIssuers
files/lib/k3s-external-secrets.sh — pure bash: install_external_secrets() — ESO Helm + ClusterSecretStore
files/lib/k3s-argocd.sh           — pure bash: install_argocd(), create_dockerhub_secret(), create_optional_app(),
                                    create_optional_apps(), configure_app_ingress(), configure_grafana_ingress(),
                                    configure_argocd_ingress(), configure_longhorn_ingress()
files/lib/k3s-agent.sh            — pure bash: k3s agent install, main entry point
gitops/apps/                 — ArgoCD Application manifests (App of Apps pattern)
gitops/network-policies/     — Default-deny NetworkPolicies (managed by network-policies.yaml App)
gitops/longhorn/             — Longhorn supplementary config: ingress (BasicAuth HTTPRoute), backup-target template, taint-toleration template (worker NoSchedule), webhook-postsync/ (PostSync hook patches failurePolicy:Ignore after each Helm sync — workaround for k3s HA konnectivity 502)
gitops/cert-manager/         — ClusterIssuer templates + ArgoCD Application template (see adoption notes)
gitops/gateway/              — Envoy Gateway config: EnvoyProxy (DaemonSet/NodePort), GatewayClass, Gateway, redirect HTTPRoute, TLS ClientTrafficPolicy
gitops/external-secrets/     — ClusterSecretStore template + example ExternalSecret CRs (enable_external_secrets)
example/         — Example module usage
Justfile         — Common operation recipes: just apply, just kubeconfig, just ssh worker, just fmt, just validate
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
  Add `moved {}` blocks to `moved.tf`. Remove them after one release cycle and leave only the header comment.

### Shell scripts (`files/`)
- **`files/server-vars.sh.tpl`** and **`files/agent-vars.sh.tpl`** are the ONLY Terraform
  templatefiles. They export all Terraform-resolved values as bash `export KEY="value"`.
  `${var}` is Terraform interpolation; these files render to a plain bash variable header.
- **`files/lib/*.sh`** are pure bash — no Terraform syntax, no `$${var}` escaping.
  ShellCheck runs on these files without workarounds (`# shellcheck disable=SC2154` is the
  only suppression, covering vars exported by the prepended template header).
- `data.tf` assembles the final script with `join("\n", [templatefile(...), file(...), ...])`.
- Ubuntu 24.04 only. No Oracle Linux, no multi-distro branches.
- Always use `set -euo pipefail` at the top of each file.

### Adding a new stack component
If the component must be bootstrapped before ArgoCD starts (e.g. it provides a CRD that
ArgoCD apps depend on):
1. Add a version variable to `vars.tf` with a `# renovate:` comment.
2. Export the version in `files/server-vars.sh.tpl` as `export MY_VERSION="${my_version}"`.
3. Write an `install_<component>()` function in the most appropriate sub-script under `files/lib/`:
   - `k3s-secrets.sh` — if it only creates Kubernetes Secrets
   - `k3s-cert-manager.sh` — if it is cert-manager or a ClusterIssuer variant
   - `k3s-external-secrets.sh` — if it is an ESO-related component
   - `k3s-argocd.sh` — if it involves ArgoCD apps or Gateway resources
   - Create a new `k3s-<component>.sh` file for completely new concerns
4. Call it from `run_bootstrap()` in `files/lib/k3s-bootstrap.sh`.
5. Add the version variable to the `templatefile()` vars map in `data.tf`.
6. If you created a new `k3s-<component>.sh`, add it to the `file(...)` list in `data.cloudinit_config.k3s_server` in `data.tf` — **before** `k3s-bootstrap.sh` so its functions are defined when the orchestrator calls them.

If the component is fully managed by ArgoCD (Helm chart from gitops/apps/):
1. Add an ArgoCD `Application` manifest to `gitops/apps/` with the chart version pinned
   and a `# renovate:` comment for automated updates.
2. No changes to cloud-init or vars.tf are needed.

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
4. `txtOwnerId` is automatically set to `var.cluster_name` by cloud-init — no manual update needed.
   (important when `enable_external_dns = true` and sharing a Cloudflare zone).
5. Add their own ArgoCD `Application` manifests to `gitops/apps/` — each can point
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
| ShellCheck | `shellcheck --severity=warning files/*.sh scripts/*.sh` |
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
shellcheck --severity=warning \
  files/lib/common.sh \
  files/lib/bootstrap-ubuntu.sh \
  files/lib/bootstrap-opensuse.sh \
  files/lib/k3s-server.sh \
  files/lib/k3s-bootstrap.sh \
  files/lib/k3s-secrets.sh \
  files/lib/k3s-cert-manager.sh \
  files/lib/k3s-external-secrets.sh \
  files/lib/k3s-argocd.sh \
  files/lib/k3s-agent.sh \
  scripts/clean-oci-resources.sh
yamllint -d '{extends: relaxed, rules: {line-length: {max: 200}}}' gitops/ .github/workflows/
actionlint
trivy config . --severity HIGH,CRITICAL --skip-dirs .terraform,example/.terraform
terraform-docs .
```

## Troubleshooting scripts

A helper script in `scripts/` addresses common failure modes. It requires `COMPARTMENT_OCID`
(your OCI tenancy or compartment OCID) and accepts an optional `CLUSTER_NAME` override (default: `k3s-oci`).

### `scripts/clean-oci-resources.sh` — full OCI resource cleanup

**When to use:** Before every rebuild. Also after a failed `tofu destroy` or when Terraform state
was wiped while OCI resources still exist.

**What it does:** Removes ALL OCI resources created by the module: logging agents/logs/groups,
MySQL, vaults (schedules all for deletion — 7-day grace period), object storage buckets, compute
instances/pools/configs, bastions, IAM dynamic groups/policies, and networking (subnets → route
tables → gateways → security lists → VCN). Retries subnet deletion up to 3× (60 s apart) to
allow OCI to release VNICs after instance termination.

```bash
COMPARTMENT_OCID=ocid1.tenancy.oc1..xxx CLUSTER_NAME=mycluster \
  ./scripts/clean-oci-resources.sh
# or via just:
COMPARTMENT_OCID=ocid1.tenancy.oc1..xxx CLUSTER_NAME=mycluster just clean-oci-resources
```

> **Vault quota:** OCI vaults have a 7-day minimum deletion grace period and count against the
> ~5-vault compartment limit even while `PENDING_DELETION`. If `tofu apply` fails with a vault
> quota error, wait for old vaults to fully delete or request a service limit increase.

---

## What NOT to do

- Do not add paid OCI resources (compute shapes other than A1.Flex, extra NLBs, etc.)
- Do not add Oracle Linux support — Ubuntu 24.04 LTS only
- Do not remove `lifecycle { prevent_destroy = true }` from load balancers
- Do not hardcode secrets, OCIDs, or credentials anywhere
- Do not remove the `# renovate:` comments on version variables
- Do not commit `example/terraform.tfvars` (it is gitignored; `.tfvars.example` is the template)
- Do not break the `terraform validate` step — `server-vars.sh.tpl` / `agent-vars.sh.tpl` vars must match what `data.tf` passes
- **Do not suggest terminating TLS at the OCI load balancer** — the public-facing LB is the OCI NLB (`nlb.tf`), which operates at L4 TCP only (`protocol = "TCP"`) and cannot inspect or terminate TLS. The one free OCI Flexible LB allocation (L7, TLS-capable) is consumed by the internal kubeapi HA LB (`lb.tf`). TLS must be terminated at Envoy Gateway. cert-manager + Let's Encrypt handles certificate issuance and renewal automatically.
- **Do not add nginx or other ingress controllers** — Envoy Gateway (Gateway API) is the ingress implementation. All HTTP/HTTPS routing uses standard `HTTPRoute`, `Gateway`, and `GatewayClass` resources.
- **Do not re-add `control-plane:NoSchedule` taints** — cloud-init removes these taints after cluster init so user workloads schedule across all 4 nodes. With only 1 worker, keeping the taints makes the worker a single point of failure for all workloads. All nodes are identically sized; etcd and user workloads coexist safely.
- **Do not add UFW or any iptables-front-end** to nodes. k3s manages iptables directly via flannel;
  adding ufw would flush k3s's rules on `ufw enable` and break pod networking. OCI NSGs provide
  the security boundary at the hypervisor level, independent of the OS firewall.
- **Vault uses `DEFAULT` type and `SOFTWARE` protection only** — `VIRTUAL_PRIVATE` vault type and `HSM` protection mode are NOT Always Free. `vault_type = "DEFAULT"` (shared vault) + `protection_mode = "SOFTWARE"` are entirely free. The 150-secret limit covers the three cluster secrets many times over. Never change the vault type or protection mode without verifying cost.
- **Vault and key have `prevent_destroy = true`** — OCI DEFAULT vaults have a low per-tenancy limit and take a minimum of 7 days to fully delete (the `PENDING_DELETION` state counts against quota). `prevent_destroy` keeps the vault alive across `tofu destroy`/`tofu apply` cycles. If you genuinely need to delete the vault, remove the `lifecycle` block or run `tofu state rm` first.
- **Do not add an nginx stream proxy** back. The OCI NLB routes directly to Envoy Gateway NodePorts
  (`is_preserve_source = true` preserves real client IPs transparently). An extra nginx hop
  adds latency and complexity with no benefit.
- **Do not reduce `boot_volume_size_in_gbs` below 50 GB** — OCI requires ≥ 50 GB for boot
  volumes on all shapes (A1.Flex and E2.1.Micro alike). 4 × 50 GB = 200 GB exactly fills the
  Always Free block storage limit. Do not suggest 47 GB as an optimisation — it is not valid.

## Special implementation notes

### expose_ssh and expose_kubeapi (direct NLB access)

- **`expose_ssh = true`** adds TCP:22 listener + backends to the public NLB and NSG rules allowing `my_public_ip_cidr` to SSH directly to nodes via the NLB IP (see `ssh_command` output).
- **`expose_kubeapi = true`** adds TCP:6443 to the NLB for direct kubeapi access without a bastion.
- When `expose_ssh = true`, OCI Bastion Service (`enable_bastion`) is redundant. Set `enable_bastion = false` to avoid the lingering-VNIC delay when destroying (OCI Bastion VNICs take 15-30 min to clean up internally after deletion, blocking subnet deletion).
- NSG rules for NLB SSH/kubeapi traffic MUST use `source_type = "CIDR_BLOCK"` with `source = var.my_public_ip_cidr`, NOT `source_type = "NETWORK_SECURITY_GROUP"`. The NLB uses `is_preserve_source = true` so real client IPs arrive at node VNICs directly — NLB NSG rules only match health-check traffic.

### Envoy Gateway (Gateway API)

- Deployed as a **DaemonSet** (one Envoy proxy pod per node) via the `EnvoyProxy` resource — every NLB backend serves ingress locally, no cross-node forwarding, no single-pod SPOF.
- `priorityClassName: system-cluster-critical` ensures Envoy proxy pods preempt user workloads under memory pressure and are never evicted before system daemons.
- `resources.requests: 100m CPU / 128Mi RAM` prevents scheduling on nodes that cannot sustain ingress load.
- `PodDisruptionBudget maxUnavailable: 1` for the Envoy DaemonSet is NOT used — Kubernetes PDB does not support DaemonSet-controlled pods (DaemonSets do not implement the scale subresource). kured uses `--ignore-daemonsets` during drain so the one-node-at-a-time guarantee comes from kured's own distributed lock, not a PDB. Do not add a PDB for the Envoy DaemonSet pods.
- All HTTP/HTTPS routing uses standard `HTTPRoute` resources (Gateway API v1). Proprietary `IngressRoute` CRDs are not used.
- HTTP-01 ACME challenges use `gatewayHTTPRoute` solver (cert-manager Gateway API integration). cert-manager is installed with `--feature-gates=ExperimentalGatewayAPISupport=true`.
- TLS certificates live in the `envoy-gateway-system` namespace (same as the Gateway) so no `ReferenceGrant` is needed.
- BasicAuth for Longhorn UI uses Envoy Gateway `SecurityPolicy` with `.htpasswd` Secret — same security, standard API.
- Do not change `envoyDaemonSet` back to `envoyDeployment` — this would reintroduce a single-pod SPOF for all HTTP/HTTPS traffic.

### Longhorn storage
- Replica count is **explicitly pinned to 3** in `gitops/apps/longhorn.yaml` via `defaultSettings.defaultReplicaCount=3` and `persistence.defaultClassReplicaCount=3`. Do not rely on the upstream chart default.
- Longhorn is managed entirely by ArgoCD (`gitops/apps/longhorn.yaml`). Cloud-init does NOT install Longhorn.
- With 4 nodes and 3 replicas, any single node can be lost without PVC data loss.
- The etcd HA ceiling applies independently: losing 2 control-plane nodes loses etcd quorum regardless of Longhorn replica count.

### Longhorn UI BasicAuth
- Password is generated by `random_password.longhorn_ui_password` in `data.tf` and exported by
  `files/server-vars.sh.tpl` as `LONGHORN_UI_PASSWORD_PLAIN` (or fetched from Vault when `enable_vault = true`).
- `files/lib/k3s-bootstrap.sh` generates the APR1 hash via `openssl passwd -apr1` and creates
  `Secret/longhorn-basic-auth-secret` in `longhorn-system` at bootstrap time. The hash requires
  runtime password resolution so it cannot be a static gitops file.
- `gitops/longhorn/ingress.yaml` is a template — users configure the `HTTPRoute`, `SecurityPolicy`,
  and `Certificate` resources there pointing to the pre-created Secret.
- Credentials are available via the `longhorn_ui_credentials` sensitive output.

### cert-manager GitOps adoption
- Cloud-init bootstraps ClusterIssuers with the correct email from `var.certmanager_email_address`.
  This must happen at bootstrap time — the email cannot be in git without manual editing.
- `gitops/cert-manager/` contains template ClusterIssuers and an ArgoCD Application template.
- To enable ArgoCD management of ClusterIssuers: update the email in `cluster-issuers.yaml`,
  then copy `application-template.yaml` to `gitops/apps/cert-manager.yaml`.
- Do NOT place the template in `gitops/apps/` as-is — it contains `changeme@example.com`.

### Cloud-init structure (`files/`)
- **Separation of concerns**: `server-vars.sh.tpl` and `agent-vars.sh.tpl` are the ONLY files
  with Terraform `${var}` interpolation. All `files/lib/*.sh` are pure bash.
- **Assembly**: `data.tf` uses `join("\n", [templatefile(vars.tpl), bootstrap-{ubuntu,opensuse}.sh, file(lib/common.sh), ...])` to
  produce a single cloud-init script. The OS-specific bootstrap file is selected by `var.os_family`. The rendered vars header is prepended, making all
  `export KEY="value"` statements available to the lib scripts at runtime.
- **Bootstrap script split**: `k3s-bootstrap.sh` is now a ~45-line orchestrator. Concerns live in
  focused sub-scripts (all pure bash, concatenated in order before `k3s-bootstrap.sh` in `data.tf`):
  - `k3s-secrets.sh` — `pre_create_secrets()`: Longhorn, Grafana, Alertmanager, MySQL, Cloudflare
  - `k3s-cert-manager.sh` — `install_certmanager()`: cert-manager Helm + ClusterIssuers
  - `k3s-external-secrets.sh` — `install_external_secrets()`: ESO Helm + ClusterSecretStore
  - `k3s-argocd.sh` — `install_argocd()`, `create_dockerhub_secret()`, `create_optional_app()`,
    `create_optional_apps()`, `configure_app_ingress()`, `configure_grafana_ingress()`,
    `configure_argocd_ingress()`, `configure_longhorn_ingress()`
  - `k3s-bootstrap.sh` — `install_gateway_api_crds()` + `run_bootstrap()` (calls the above)
- **GitOps-first**: cloud-init only bootstraps what ArgoCD cannot self-manage:
  - Gateway API CRDs (must exist before ArgoCD syncs `gateway-config` app)
  - cert-manager Helm + ClusterIssuers (email is a runtime Terraform var, not static git)
  - ArgoCD Helm + App of Apps bootstrap
  - External Secrets Operator Helm + ClusterSecretStore (conditional, vault_ocid is runtime)
  - Pre-create Kubernetes Secrets with runtime values (passwords, endpoints)
  - Hostname-specific HTTPS Gateway listener + TLS Certificate + HTTPRoute (NLB IP is runtime; see `configure_grafana_ingress()` in `k3s-argocd.sh` and the "Hostname-specific HTTPS resources" section in Deploying web apps)
- **Managed by ArgoCD, NOT cloud-init**: Envoy Gateway, Longhorn, kured,
  system-upgrade-controller, external-dns Helm — all in `gitops/apps/*.yaml`.
- **Removed vars**: `kured_start_time`, `kured_end_time`, `kured_reboot_days`, `kured_chart_version`,
  `longhorn_chart_version`, `envoy_gateway_chart_version`, `external_dns_chart_version` were
  removed from `vars.tf`. Configure kured via `gitops/apps/kured.yaml` directly.
- **Shared cloud-init vars**: `local.k3s_common_cloud_init_vars` in `locals.tf` holds the five
  vars shared by both server and agent (`k3s_version`, `k3s_subnet`, `k3s_token`, `k3s_url`,
  `vault_secret_id_k3s_token`). The server templatefile call uses `merge(local.k3s_common_cloud_init_vars, {...server-only...})`; the agent call passes the local directly.
- **Flannel interface resolution**: `resolve_flannel_params()` in `common.sh` sets `LOCAL_IP` and
  `FLANNEL_IFACE` (exported) when `K3S_SUBNET` is not `default_route_table`. Called by both
  `install_k3s_server()` and `install_k3s_agent()`; server adds `--advertise-address` too.
- **ShellCheck**: `# shellcheck disable=SC2154` at the top of each lib/ file covers exported vars
  from the prepended template header. No other suppressions are needed.

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

### Tailscale operator (`enable_tailscale`)
- Controlled by `enable_tailscale` variable (default: `false`). Requires `enable_vault = true`.
- Stores two Vault secrets: `${cluster_name}-tailscale-oauth-client-id` and `${cluster_name}-tailscale-oauth-client-secret`.
- Pre-requisite: create an OAuth client at https://login.tailscale.com/admin/settings/oauth — scope `Devices → Write (devices:core:write)`, allowed tag `tag:k8s-operator`. Scopes cannot be changed after creation.
- `tailscale_vault_secret_names` output shows the generated secret names; reference these in `platform/<cluster>/tailscale-operator/oauth-secret.yaml` ExternalSecret.
- The Tailscale operator Helm chart + RBAC is NOT bootstrapped by cloud-init — it is deployed by ArgoCD using the manifests in the consumer repo (`clusters/<cluster>/tailscale-operator.yaml`).
- Using Tailscale LoadBalancer Services: add `loadBalancerClass: tailscale` + `tailscale.com/hostname: <name>` annotation; the operator creates a proxy pod and registers `<name>.<tailnet>.ts.net`.
- **Tailscale VIP IPs are dynamic** — the IP assigned to a Tailscale LoadBalancer Service changes on every cluster rebuild (new proxy pod, new Tailscale identity). Consumer repos must not hardcode these IPs in DNS or config. Instead, read the IP after deploy (`kubectl get svc -o jsonpath='{.status.loadBalancer.ingress[*].ip}'`) and update DNS records programmatically as a post-deploy step.

### OCI Vault (`vault.tf`)
- Controlled by `enable_vault` variable (default: `true`).
- Uses `vault_type = "DEFAULT"` (shared vault, free). `VIRTUAL_PRIVATE` vaults cost money — never use that type.
- Key uses `protection_mode = "SOFTWARE"` (free). HSM-protected keys are NOT free.
- Stores three secrets: `k3s_token`, `longhorn_ui_password`, `grafana_admin_password`.
- Cloud-init fetches secrets at boot via `oci secrets secret-bundle get-secret-bundle` with `OCI_CLI_AUTH=instance_principal`.
- When `enable_vault = false`, the plaintext values are exported by `server-vars.sh.tpl` / `agent-vars.sh.tpl` as `K3S_TOKEN_PLAIN`, `LONGHORN_UI_PASSWORD_PLAIN`, `GRAFANA_ADMIN_PASSWORD_PLAIN`; the lib scripts use them as fallback.
- The IAM policy uses `concat()` to add `read secret-family` only when `enable_vault = true`.
- Agent script (`files/lib/k3s-agent.sh`) installs OCI CLI and fetches k3s_token from Vault when `VAULT_SECRET_ID_K3S_TOKEN` is non-empty.

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
- ⚠️ **ONS authentication limitation**: The OCI Notifications PublishMessage endpoint requires OCI IAM request signing. Alertmanager sends **unsigned** HTTP POSTs, which OCI rejects with HTTP 401. The OCI webhook receiver will silently fail. The `alertmanager_email` subscription works correctly (OCI delivers email internally, no signing needed). For Alertmanager webhook delivery, use a signing proxy, an OCI Function, or a third-party receiver (Slack, PagerDuty, etc.) instead.

### MySQL HeatWave (`mysql.tf`)
- Controlled by `enable_mysql` variable (default: `false`).
- Uses `shape_name = var.mysql_shape` (default `"MySQL.Free"` — the Always Free shape).
- Placed in the private subnet, reachable by all k3s nodes on port 3306.
- Admin password generated by `random_password.mysql_admin_password` (in `mysql.tf`).
- Cloud-init pre-creates a `mysql-credentials` Kubernetes Secret in the `default` namespace.
- `mysql_endpoint` and `mysql_admin_credentials` (sensitive) outputs are available after apply.
- `is_highly_available = false` — HA MySQL is NOT Always Free.

### External DNS (`enable_external_dns`)
- Controlled by `enable_external_dns` variable (default: `false`).
- Installs External DNS (chart version tracked by Renovate) configured for the Cloudflare provider.
- Syncs `HTTPRoute` hostnames to Cloudflare DNS automatically — annotate resources with
  `external-dns.alpha.kubernetes.io/hostname: your.host.example.com`.
- Requires `cloudflare_api_token` and `cloudflare_zone_id`.
- `external_dns_domain_filter` limits which zones External DNS manages (prevents accidental changes
  to unrelated zones when the API token covers multiple zones).
- `domainFilters`, `zoneIdFilters`, and `txtOwnerId` are injected at bootstrap time by
  `create_external_dns_app()` in `files/lib/k3s-argocd.sh` using runtime Terraform variables.
  The `gitops/optional/external-dns.yaml` file is a reference template only and is NOT applied directly.

### External Secrets (`enable_external_secrets`)
- Controlled by `enable_external_secrets` variable (default: `false`). Requires `enable_vault = true`.
- Installs External Secrets Operator and creates a `ClusterSecretStore` backed by OCI Vault using
  instance_principal auth — no credentials to rotate.
- The existing IAM `read secret-family` policy (added when `enable_vault = true`) already covers it.
- See `gitops/external-secrets/` for the ClusterSecretStore template and example ExternalSecret CRs.
- Users create `ExternalSecret` resources referencing Vault secret OCIDs; the operator syncs them
  into Kubernetes Secrets automatically and rotates on the configured refresh interval.

### Adding HTTPS ingress for a new app

Use `configure_app_ingress()` in `files/lib/k3s-argocd.sh` when a new cluster component needs
an HTTPS endpoint with a cert-manager TLS certificate. The generic helper handles the three
required resources atomically (Gateway listener, Certificate, HTTPRoute) using SSA so ArgoCD
reconciliation never removes cloud-init-owned fields.

**Signature:**
```bash
configure_app_ingress <hostname> <namespace> <service> <port> <listener_name> [route_name]
```

`route_name` is optional and defaults to `<service>`. Set it explicitly when the gitops HTTPRoute file uses a different name from the backend service (e.g. `grafana` vs `kube-prometheus-stack-grafana`).

**To add a new cloud-init-managed HTTPS app:**
1. Add `var.myapp_hostname` to `vars.tf` (nullable string, default null).
2. Add `local.myapp_hostname` to `locals.tf` (sslip.io fallback or just `var.myapp_hostname`).
3. Export `MYAPP_HOSTNAME="${myapp_hostname}"` in `files/server-vars.sh.tpl`.
4. Add `myapp_hostname = local.myapp_hostname` to the `templatefile()` vars map in `data.tf`.
5. In `files/lib/k3s-argocd.sh`, add:
   ```bash
   configure_myapp_ingress() {
     export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
     configure_app_ingress \
       "${MYAPP_HOSTNAME}" \
       "my-namespace" \
       "my-service" \
       "8080" \
       "https-myapp"
   }
   ```
6. Call it from `run_bootstrap()` in `k3s-bootstrap.sh` with error-check:
   ```bash
   configure_myapp_ingress || { echo "ERROR: configure_myapp_ingress failed"; exit 1; }
   ```
7. Add `ignoreDifferences` for the new listener in `gitops/apps/gateway-config.yaml`
   — it's already covered by the `jqPathExpression` targeting `https-*` listener names.

**Note:** For apps that also need BasicAuth (like Longhorn), add the `SecurityPolicy` resource
after calling `configure_app_ingress()`. See `configure_longhorn_ingress()` as the reference.

### Deploying web apps — known pitfalls

The following issues were discovered while deploying the first HTTPS application. Document them here so agents do not repeat the investigation.

**NLB `is_preserve_source = true` and NSG rules**

The public NLB uses `is_preserve_source = true` on all backend sets. This means packets arrive at node VNICs with the **real client IP** as source, not the NLB's own IP. NSG rules that use `source_type = NETWORK_SECURITY_GROUP` pointing at the NLB NSG will only match health-check traffic (which originates from the NLB's VNIC) — real user traffic is silently dropped. NodePort rules for HTTP (:30080) and HTTPS (:30443) on both the workers NSG and the servers NSG (servers are also NLB backends) must use `source = "0.0.0.0/0"` with `source_type = "CIDR_BLOCK"`. Nodes are in a private subnet with no public IPs, so this is safe.

**cert-manager HTTP-01 self-check blocked by NetworkPolicy**

`gitops/network-policies/cert-manager.yaml` deploys egress NetworkPolicies that kube-router enforces strictly. The original `allow-https-egress` policy only permitted TCP 443/6443/8443 — it did NOT allow TCP 80. cert-manager's HTTP-01 solver performs a self-check GET request to `http://<hostname>/.well-known/acme-challenge/...` before submitting to Let's Encrypt. With port 80 egress blocked, kube-router REJECTs the packet with ICMP port-unreachable, which Go's `net/http` reports as "connection refused". The `allow-http-egress` NetworkPolicy was added to fix this — do not remove it.

**CHACHA20_POLY1305 ciphers crash Envoy TLS on aarch64**

`gitops/gateway/tls-policy.yaml` (`ClientTrafficPolicy`) must NOT include `TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305` or `TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305`. Envoy/BoringSSL on aarch64 rejects these TLS 1.2 cipher names with error code 13, which causes the **entire xDS TLS snapshot to be rejected**. The result is that no TLS certificate is ever loaded via SDS and all HTTPS connections are dropped with TCP RST. The AES-GCM ciphers are sufficient; TLS 1.3 ChaCha20 (`TLS_CHACHA20_POLY1305_SHA256`) still negotiates automatically and is unaffected.

**HTTPRoute `hostnames: []` matches ALL requests**

An empty `hostnames` list in a Gateway API `HTTPRoute` is identical to omitting the field — it matches every hostname. An HTTP-to-HTTPS redirect route with no (or empty) `hostnames` redirects ALL HTTP traffic. cert-manager's ACME HTTP-01 challenge HTTPRoute (created automatically by cert-manager) has a more specific hostname+path match and takes precedence — so the match-all redirect is safe. `gitops/gateway/redirect.yaml` intentionally omits `hostnames` for exactly this reason. Do NOT add explicit hostnames to the redirect route — the route would break for any hostname not listed.

**Hostname-specific HTTPS resources are managed by cloud-init, not gitops/**

NLB IP changes on every redeploy. Hardcoding sslip.io addresses in `gitops/` breaks GitOps: every redeploy requires manual file edits. The design:
- `local.grafana_hostname` in `locals.tf` auto-computes `grafana.<nlb-ip>.sslip.io` (or uses `var.grafana_hostname` if set).
- `local.argocd_hostname` auto-computes `argocd.<nlb-ip>.sslip.io` (or uses `var.argocd_hostname` if set).
- `local.longhorn_hostname` uses `var.longhorn_hostname` (no sslip.io fallback — Longhorn UI is opt-in).
- `files/server-vars.sh.tpl` exports `GRAFANA_HOSTNAME`, `ARGOCD_HOSTNAME`, `LONGHORN_HOSTNAME`.
- `files/lib/k3s-argocd.sh:configure_app_ingress(hostname namespace service port listener_name)` is the generic helper.
  - Creates the Gateway HTTPS listener (SSA, field-manager=cloud-init-bootstrap)
  - Creates the cert-manager Certificate in `envoy-gateway-system`
  - Creates the app HTTPRoute in the app namespace (SSA, field-manager=cloud-init-bootstrap)
- `configure_grafana_ingress()`, `configure_argocd_ingress()`, `configure_longhorn_ingress()` each call the generic helper.
- `configure_longhorn_ingress()` additionally applies the `SecurityPolicy` for BasicAuth.
- `gitops/gateway/gateway.yaml` has ONLY the `http` listener (ArgoCD owns it via SSA).
- `gitops/monitoring/grafana-ingress.yaml` has the Grafana HTTPRoute WITHOUT `hostnames` (ArgoCD owns all fields except `spec.hostnames`, which cloud-init-bootstrap owns).

**SSA field-manager ownership prevents ArgoCD from clearing cloud-init patches**

Gateway API's `spec.listeners` is a `x-kubernetes-list-map-keys: [name]` list — SSA treats it as a named map and merges by the `name` key. Each SSA manager owns the entries it applied:
- `argocd-controller` owns `spec.listeners[name=http]` (applied from gateway.yaml)
- `cloud-init-bootstrap` owns `spec.listeners[name=https-grafana]` (applied by configure_grafana_ingress)
When ArgoCD syncs gateway.yaml (without `https-grafana`), it only owns `http` and never touches `https-grafana`. The `ignoreDifferences: /spec/listeners` in gateway-config ArgoCD Application suppresses OutOfSync warnings.

Similarly, `spec.hostnames` in the Grafana HTTPRoute is owned by `cloud-init-bootstrap` (via `kubectl apply --server-side --field-manager=cloud-init-bootstrap --force-conflicts`). ArgoCD's SSA apply (without `hostnames` in the manifest) doesn't claim or clear the field.

**Do NOT use CSA (kubectl apply without --server-side) to patch ArgoCD-managed resources.** CSA sets the `kubectl.kubernetes.io/last-applied-configuration` annotation, which confuses ArgoCD's 3-way merge on the next sync. Always use SSA with a custom field-manager for cloud-init patches to ArgoCD-managed resources.

**gateway-config MUST use ServerSideApply=true** to avoid `resourceVersion: 0` errors. Without SSA, ArgoCD's CSA apply with `RespectIgnoreDifferences` strips `spec.listeners` from the patch payload, causing a malformed UPDATE request to fail validation.

### Feature flag co-dependencies (`checks.tf`)
Terraform 1.9+ `check {}` blocks in `checks.tf` catch invalid feature flag combinations at plan time
before any OCI API call is made:
- `enable_external_secrets = true` requires `enable_vault = true` and `region != null`
- `enable_dns01_challenge = true` requires `cloudflare_api_token != null`
- `enable_external_dns = true` requires `cloudflare_api_token`, `cloudflare_zone_id`, and `external_dns_domain_filter`
- `enable_tailscale = true` requires `enable_vault = true` and both `tailscale_oauth_client_id` and `tailscale_oauth_client_secret` set

These produce a clear error message (not a cryptic apply-time failure) when the combination is invalid.
Do not remove these checks.

### Variable validations
The following variables have explicit format validation to prevent late-apply OCI API failures:
- `cluster_name`: `^[a-z0-9][a-z0-9-]{1,28}[a-z0-9]$` — OCI resource name limits; used as prefix in all display names
- `availability_domain`: `^[^:]+:[A-Z0-9]+-AD-[1-3]$` — OCI format requirement
- `my_public_ip_cidr`: must be a valid CIDR
- `certmanager_email_address`: must be a valid email, not the placeholder
- `os_image_id`: must start with `ocid1.image.` if set
- `oci_core_vcn_dns_label`, `public_subnet_dns_label`, `private_subnet_dns_label`: `^[a-zA-Z0-9]{1,15}$` — OCI DNS label limits (no hyphens, max 15 chars)
- `boot_volume_size_in_gbs`: must be `>= 50` (OCI hard minimum)
- `k3s_server_pool_size`: must be odd positive integer (etcd quorum)

When adding a new variable that maps to an OCI resource name or OCID, add a `validation {}` block.

### DNS-01 ACME challenge (`enable_dns01_challenge`)
- Controlled by `enable_dns01_challenge` variable (default: `false`). Requires `cloudflare_api_token`.
- When enabled, cloud-init creates a `cloudflare-api-token` Secret in `cert-manager` and switches
  ClusterIssuers to use DNS-01 (Cloudflare) instead of HTTP-01.
- Benefits: supports wildcard certs (`*.example.com`), no inbound port 80 required.
- See `gitops/cert-manager/cluster-issuers.yaml` for the commented DNS-01 ClusterIssuer variants
  to use when adopting cert-manager into ArgoCD.

### etcd Snapshots (`enable_etcd_snapshots`)
- Controlled by `enable_etcd_snapshots` variable (default: `true`). Requires `enable_object_storage_state = true`.
- Cloud-init installs `/usr/local/bin/etcd-snapshot-upload.sh` + cron job on the first server (every 6h).
- Snapshots are uploaded to `${cluster_name}-terraform-state` bucket under `etcd-snapshots/${CLUSTER_NAME}/` using OCI CLI instance_principal auth — **no Customer Secret Keys required**.
- IAM policy `manage objects in bucket ${cluster_name}-terraform-state` (added in `iam.tf`) enables this.
- Retention is configurable via `etcd_snapshot_retention` (default: 5 snapshots).
- These snapshots are the primary recovery path for split-brain and etcd quorum loss. See `README.md#split-brain-recovery`.

### Atomic leader lock (`--cluster-init` safety)
- `claim_first_server_lock()` in `files/lib/k3s-server.sh` uses **`oci os object put --no-overwrite`** to OCI Object Storage before running `--cluster-init`. `--no-overwrite` maps to server-side If-None-Match: * and is the correct native atomic conditional-create primitive — it exits non-zero when the object already exists. **Do NOT use `--if-none-match` (not a valid CLI flag) or `oci raw-request --request-body-file` (also not a valid flag).**
- Lock object: `cluster-init-lock` in the `${cluster_name}-terraform-state` bucket.
- If the lock already exists and the holder's instance is still RUNNING, the node switches to join mode (resolving the holder's IP from `LOCK_HOLDER_OCID`) instead of aborting with exit 1 — this handles TIMECREATED-tie scenarios where two nodes elect themselves simultaneously.
- Stale locks (different cluster name, or holder instance terminated) are automatically overwritten. A cluster-reachability probe (`_probe_existing_cluster()`) prevents re-init if a live cluster is still reachable after reclaim.
- On a deliberate full rebuild (destroy + apply), delete the stale lock: `oci os object delete --bucket-name ${cluster_name}-terraform-state --name cluster-init-lock --force`.
- When Object Storage is not configured (`ETCD_SNAPSHOT_BUCKET` empty), the lock is skipped and the TIMECREATED election alone determines the first server.

### etcd Monitoring
- `kube-prometheus-stack.yaml` has `defaultRules.rules.etcd: true` — **do not disable**. These rules (EtcdNoLeader, EtcdInsufficientMembers, EtcdMembersDown, EtcdHighFsyncDurations) are the primary signals for split-brain.
- etcd metrics are exposed on `:2381` via `--etcd-expose-metrics` (added to `install_k3s_server()` in `k3s-server.sh`).
- `additionalScrapeConfigs` in `kube-prometheus-stack.yaml` uses `kubernetes_sd_configs` to discover control-plane nodes and scrape `:2381/metrics` automatically.
- NSG rule `servers_allow_etcd_metrics` in `nsg.tf` opens TCP 2381 from `private_subnet_cidr` for in-cluster Prometheus scraping.

### Fail-closed split-brain fallback
- `install_k3s_server()` in `k3s-server.sh`: when `IS_FIRST_SERVER=false`, joining nodes **abort** if `FIRST_SERVER_IP` is empty (OCI API failure during election), instead of falling back to `K3S_URL` (the internal LB).
- **Do NOT reintroduce `${FIRST_SERVER_IP:-${K3S_URL}}`** — that fallback is the exact path that caused the documented split-brain issues. The internal LB routes to UNKNOWN-state backends for ~30s after creation, which can route a joining server's bootstrap to another uninitialised node.

### Longhorn replica count
- Default replica count is **2** (down from 3). With 50 GB boot-only volumes (~30 GB usable after OS/images/etcd), 3 replicas leaves only ~20-30 GB cluster-wide PVC capacity.
- Use `storageClassName: longhorn-replicated-3` (defined in `gitops/longhorn/storageclasses/`) for explicitly critical PVCs requiring 3-replica protection.
- **Do not increase the default back to 3** without acknowledging the storage budget impact.

### Longhorn sync-wave
- `gitops/apps/longhorn.yaml` has `argocd.argoproj.io/sync-wave: "-1"` — **do not remove**. This ensures Longhorn converges and its StorageClass is ready before `kube-prometheus-stack` (wave 0) creates PVCs. Without it, Prometheus PVCs sit Pending for 10-30 minutes on first boot.

### Upgrade plan PDB behaviour
- `gitops/system-upgrade/plans.yaml` does NOT use `disableEviction: true` — **do not add it back**. With `disableEviction`, the server and agent upgrade plans can drain nodes simultaneously, reducing Longhorn to 1 replica during rebuild. Without it, the `longhorn-manager minAvailable: 2` PDB prevents concurrent drains.

### Internal LB health check
- `lb.tf` uses HTTP health check on `/readyz` (not TCP). A server with dead etcd fails `/readyz` but passes TCP. **Do not revert to TCP** — it would keep dead-etcd servers in the backend rotation.
