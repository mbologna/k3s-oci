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
data.tf          — cloud-init assembly (join of vars tpl + lib files), random_password resources
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
files/server-vars.sh.tpl     — cloud-init header for servers: ONLY file with Terraform ${var} syntax
files/agent-vars.sh.tpl      — cloud-init header for agents: ONLY file with Terraform ${var} syntax
files/lib/common.sh          — pure bash: OS bootstrap, unattended-upgrades, OCI CLI, Helm, resolve_flannel_params()
files/lib/k3s-server.sh      — pure bash: first-server election, k3s install, main entry point
files/lib/k3s-bootstrap.sh   — pure bash: secrets pre-creation, Gateway API CRDs, cert-manager, ArgoCD
files/lib/k3s-agent.sh       — pure bash: k3s agent install, main entry point
gitops/apps/                 — ArgoCD Application manifests (App of Apps pattern)
gitops/network-policies/     — Default-deny NetworkPolicies (managed by network-policies.yaml App)
gitops/longhorn/             — Longhorn ingress with BasicAuth (Envoy Gateway SecurityPolicy + HTTPRoute)
gitops/cert-manager/         — ClusterIssuer templates + ArgoCD Application template (see adoption notes)
gitops/gateway/              — Envoy Gateway config: EnvoyProxy (DaemonSet/NodePort), GatewayClass, Gateway, redirect HTTPRoute, TLS ClientTrafficPolicy
gitops/external-secrets/     — ClusterSecretStore template + example ExternalSecret CRs (enable_external_secrets)
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
  Remove `moved {}` blocks after one release cycle — leave a comment in `moved.tf` explaining
  that it's intentionally empty. The file itself must remain so its purpose is clear.

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
3. Write an `install_<component>()` function in `files/lib/k3s-bootstrap.sh`.
4. Call it from `run_bootstrap()` in `k3s-bootstrap.sh`.
5. Add the version variable to the `templatefile()` vars map in `data.tf`.

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
4. Update `txtOwnerId` in `gitops/apps/external-dns.yaml` to match `var.cluster_name`
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
shellcheck --severity=warning files/lib/common.sh files/lib/k3s-server.sh files/lib/k3s-bootstrap.sh files/lib/k3s-agent.sh
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
- Do not break the `terraform validate` step — `server-vars.sh.tpl` / `agent-vars.sh.tpl` vars must match what `data.tf` passes
- **Do not suggest terminating TLS at the OCI load balancer** — the public-facing LB is the OCI NLB (`nlb.tf`), which operates at L4 TCP only (`protocol = "TCP"`) and cannot inspect or terminate TLS. The one free OCI Flexible LB allocation (L7, TLS-capable) is consumed by the internal kubeapi HA LB (`lb.tf`). TLS must be terminated at Envoy Gateway. cert-manager + Let's Encrypt handles certificate issuance and renewal automatically.
- **Do not add nginx or other ingress controllers** — Envoy Gateway (Gateway API) is the ingress implementation. All HTTP/HTTPS routing uses standard `HTTPRoute`, `Gateway`, and `GatewayClass` resources.
- **Do not re-add `control-plane:NoSchedule` taints** — cloud-init removes these taints after cluster init so user workloads schedule across all 4 nodes. With only 1 worker, keeping the taints makes the worker a single point of failure for all workloads. All nodes are identically sized; etcd and user workloads coexist safely.
- **Do not add UFW or any iptables-front-end** to nodes. k3s manages iptables directly via flannel;
  adding ufw would flush k3s's rules on `ufw enable` and break pod networking. OCI NSGs provide
  the security boundary at the hypervisor level, independent of the OS firewall.
- **Vault uses `DEFAULT` type and `SOFTWARE` protection only** — `VIRTUAL_PRIVATE` vault type and `HSM` protection mode are NOT Always Free. `vault_type = "DEFAULT"` (shared vault) + `protection_mode = "SOFTWARE"` are entirely free. The 150-secret limit covers the three cluster secrets many times over. Never change the vault type or protection mode without verifying cost.
- **Do not add an nginx stream proxy** back. The OCI NLB routes directly to Envoy Gateway NodePorts
  (`is_preserve_source = true` preserves real client IPs transparently). An extra nginx hop
  adds latency and complexity with no benefit.
- **Do not reduce `boot_volume_size_in_gbs` below 50 GB** — OCI requires ≥ 50 GB for boot
  volumes on all shapes (A1.Flex and E2.1.Micro alike). 4 × 50 GB = 200 GB exactly fills the
  Always Free block storage limit. Do not suggest 47 GB as an optimisation — it is not valid.

## Special implementation notes

### Envoy Gateway (Gateway API)

- Deployed as a **DaemonSet** (one Envoy proxy pod per node) via the `EnvoyProxy` resource — every NLB backend serves ingress locally, no cross-node forwarding, no single-pod SPOF.
- `priorityClassName: system-cluster-critical` ensures Envoy proxy pods preempt user workloads under memory pressure and are never evicted before system daemons.
- `resources.requests: 100m CPU / 128Mi RAM` prevents scheduling on nodes that cannot sustain ingress load.
- `PodDisruptionBudget maxUnavailable: 1` (`envoy-gateway-pdb`) is applied so kured/drain can only take down one proxy pod at a time — 3 of 4 nodes always serve ingress during rolling maintenance.
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
- **Assembly**: `data.tf` uses `join("\n", [templatefile(vars.tpl), file(lib/common.sh), ...])` to
  produce a single cloud-init script. The rendered vars header is prepended, making all
  `export KEY="value"` statements available to the lib scripts at runtime.
- **GitOps-first**: cloud-init only bootstraps what ArgoCD cannot self-manage:
  - Gateway API CRDs (must exist before ArgoCD syncs `gateway-config` app)
  - cert-manager Helm + ClusterIssuers (email is a runtime Terraform var, not static git)
  - ArgoCD Helm + App of Apps bootstrap
  - External Secrets Operator Helm + ClusterSecretStore (conditional, vault_ocid is runtime)
  - Pre-create Kubernetes Secrets with runtime values (passwords, endpoints)
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
- **ShellCheck**: `# shellcheck disable=SC2154` in lib/ files covers exported vars from the
  prepended template header. No other suppressions needed (was 5+ in the old monolith).

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
- `txtOwnerId` is hardcoded to `k3s-cluster` in `gitops/apps/external-dns.yaml`; update it to match `var.cluster_name` in your fork so multiple clusters can share a Cloudflare zone without conflicts.

### External Secrets (`enable_external_secrets`)
- Controlled by `enable_external_secrets` variable (default: `false`). Requires `enable_vault = true`.
- Installs External Secrets Operator and creates a `ClusterSecretStore` backed by OCI Vault using
  instance_principal auth — no credentials to rotate.
- The existing IAM `read secret-family` policy (added when `enable_vault = true`) already covers it.
- See `gitops/external-secrets/` for the ClusterSecretStore template and example ExternalSecret CRs.
- Users create `ExternalSecret` resources referencing Vault secret OCIDs; the operator syncs them
  into Kubernetes Secrets automatically and rotates on the configured refresh interval.

### Deploying web apps — known pitfalls

The following issues were discovered while deploying the first HTTPS application. Document them here so agents do not repeat the investigation.

**NLB `is_preserve_source = true` and NSG rules**

The public NLB uses `is_preserve_source = true` on all backend sets. This means packets arrive at node VNICs with the **real client IP** as source, not the NLB's own IP. NSG rules that use `source_type = NETWORK_SECURITY_GROUP` pointing at the NLB NSG will only match health-check traffic (which originates from the NLB's VNIC) — real user traffic is silently dropped. NodePort rules for HTTP (:30080) and HTTPS (:30443) on both the workers NSG and the servers NSG (servers are also NLB backends) must use `source = "0.0.0.0/0"` with `source_type = "CIDR_BLOCK"`. Nodes are in a private subnet with no public IPs, so this is safe.

**cert-manager HTTP-01 self-check blocked by NetworkPolicy**

`gitops/network-policies/cert-manager.yaml` deploys egress NetworkPolicies that kube-router enforces strictly. The original `allow-https-egress` policy only permitted TCP 443/6443/8443 — it did NOT allow TCP 80. cert-manager's HTTP-01 solver performs a self-check GET request to `http://<hostname>/.well-known/acme-challenge/...` before submitting to Let's Encrypt. With port 80 egress blocked, kube-router REJECTs the packet with ICMP port-unreachable, which Go's `net/http` reports as "connection refused". The `allow-http-egress` NetworkPolicy was added to fix this — do not remove it.

**CHACHA20_POLY1305 ciphers crash Envoy TLS on aarch64**

`gitops/gateway/tls-policy.yaml` (`ClientTrafficPolicy`) must NOT include `TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305` or `TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305`. Envoy/BoringSSL on aarch64 rejects these TLS 1.2 cipher names with error code 13, which causes the **entire xDS TLS snapshot to be rejected**. The result is that no TLS certificate is ever loaded via SDS and all HTTPS connections are dropped with TCP RST. The AES-GCM ciphers are sufficient; TLS 1.3 ChaCha20 (`TLS_CHACHA20_POLY1305_SHA256`) still negotiates automatically and is unaffected.

**HTTPRoute `hostnames: []` matches ALL requests**

An empty `hostnames` list in a Gateway API `HTTPRoute` is identical to omitting the field — it matches every hostname. A catch-all redirect route that applies to ALL HTTP traffic will intercept ACME HTTP-01 challenge requests and break certificate issuance. Scope redirect routes to explicit hostnames. See `gitops/gateway/redirect.yaml`.

### DNS-01 ACME challenge (`enable_dns01_challenge`)
- Controlled by `enable_dns01_challenge` variable (default: `false`). Requires `cloudflare_api_token`.
- When enabled, cloud-init creates a `cloudflare-api-token` Secret in `cert-manager` and switches
  ClusterIssuers to use DNS-01 (Cloudflare) instead of HTTP-01.
- Benefits: supports wildcard certs (`*.example.com`), no inbound port 80 required.
- See `gitops/cert-manager/cluster-issuers.yaml` for the commented DNS-01 ClusterIssuer variants
  to use when adopting cert-manager into ArgoCD.
