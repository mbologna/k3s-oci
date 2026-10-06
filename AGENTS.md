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
| OS | Ubuntu 26.04 LTS (aarch64) — default. openSUSE Leap (aarch64) via `var.os_family = "opensuse"` |
| Kubernetes | k3s (latest resolved at plan time) |
| Ingress | Envoy Gateway (Gateway API) |
| Logging | OCI Unified Logging (optional) |
| Storage | Longhorn |
| GitOps | ArgoCD + Image Updater |
| TLS | cert-manager (Let's Encrypt) |
| Reboots | kured + unattended-upgrades |

## Always Free budget — hard constraints

| Resource | Free allowance | This module |
|---|---|---|
| A1.Flex compute | 2 OCPUs / 12 GB / 2 instances | 1 server + 1 standalone worker |
| Block storage | 200 GB | 2 × 100 GB boot volumes = 200 GB (`boot_volume_size_in_gbs = 100`, enforced by a `checks.tf` budget check); bastion is OCI Bastion Service (managed, no VM, no storage) |
| NLB | 1 | 1 public NLB |
| Flex LB | 1 × 10 Mbps | 1 internal LB |
| E2.1.Micro | 2 | 0 (bastion uses OCI Bastion Service, not a VM) |
| NAT Gateway | 1 per VCN | 1 |
| Object Storage | 20 GB (Free Tier) / 10 GB (Pay As You Go) | 2 versioned buckets — Terraform state (`enable_object_storage_state`) + Longhorn PVC backups (`enable_longhorn_backup`) |
| Vault (shared) | Software keys + 150 secrets | 2–9 secrets (`enable_vault = true`) — see the OCI Vault section for the full list |
| Volume backups | 5 total | 2 — one per node, weekly, 1-week retention (`enable_backup = true`) |
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
iam.tf           — Dynamic Group (compartment-scoped — tag matching breaks instance_principal) and Policy (log-content, secret-family, state-bucket objects); Longhorn backup service user/group/policy (create_longhorn_backup_user)
logging.tf       — OCI Log Group, Log, Unified Agent Configuration (enabled via enable_oci_logging)
compute.tf       — Instance pool (servers), pool (workers), standalone extra worker
lb.tf            — Internal Flexible LB (kubeapi endpoint for agents; TCP health check)
nlb.tf           — Public Network LB (HTTP/HTTPS ingress); backend sets/listeners use for_each over nlb_web_protocols local
backup.tf        — Custom weekly backup policy + assignments for all node boot volumes (enable_backup)
vault.tf         — OCI Vault (DEFAULT type, SOFTWARE key) + 2–9 cluster secrets (full list in the OCI Vault section)
objectstorage.tf — Versioned buckets: <cluster>-terraform-state (etcd snapshots + leader lock, NOT tofu state; enable_object_storage_state) and <cluster>-longhorn-backup (enable_longhorn_backup), each with a noncurrent-version lifecycle rule
bastion.tf       — OCI Bastion Service (managed, no VM; enable_bastion)
mysql.tf         — MySQL HeatWave DB system in private subnet (enable_mysql)
output.tf        — Outputs (IPs, k3s_token, longhorn_ui_credentials, argocd_initial_password_hint, oci_log_group_id, terraform_state_backend, mysql_endpoint, vault_id, tailscale_vault_secret_names)
files/server-vars.sh.tpl          — cloud-init header for servers: ONLY file with Terraform ${var} syntax
files/agent-vars.sh.tpl           — cloud-init header for agents: ONLY file with Terraform ${var} syntax
files/kubeconfig-hint-bastion.tpl     — kubeconfig retrieval instructions when bastion is enabled
files/kubeconfig-hint-no-bastion.tpl  — kubeconfig retrieval instructions when bastion is disabled
files/lib/common.sh               — pure bash: OS-agnostic helpers: setup_shared_ssh_host_key(), configure_longhorn_prereqs(), install_oci_cli(), install_helm(), resolve_flannel_params()
files/lib/bootstrap-ubuntu.sh    — pure bash: Ubuntu bootstrap: wait_apt_lock(), bootstrap(), configure_unattended_upgrades() (apt, unattended-upgrades, needrestart)
files/lib/bootstrap-opensuse.sh  — pure bash: openSUSE bootstrap: bootstrap(), configure_unattended_upgrades() (zypper, /usr/local/sbin/zypper-patch-with-sentinel, kured sentinel)
files/lib/k3s-server.sh           — pure bash: first-server election, k3s install, main entry point
files/lib/k3s-bootstrap.sh        — pure bash: orchestrator — calls install_gateway_api_crds() then run_bootstrap()
files/lib/k3s-secrets.sh          — pure bash: pre_create_secrets() — Longhorn, MySQL, Cloudflare secrets
files/lib/k3s-cert-manager.sh     — pure bash: install_certmanager() — cert-manager Helm + ClusterIssuers
files/lib/k3s-external-secrets.sh — pure bash: install_external_secrets() — ESO Helm + ClusterSecretStore
files/lib/k3s-argocd.sh           — pure bash: install_argocd(), create_dockerhub_secret(), create_optional_app(),
                                    create_optional_apps(), create_external_dns_app(), configure_app_ingress(),
                                    configure_argocd_ingress(), configure_longhorn_ingress()
files/lib/k3s-agent.sh            — pure bash: k3s agent install, main entry point
gitops/apps/                 — ArgoCD Application manifests (App of Apps pattern)
gitops/optional/             — Opt-in Applications outside the App of Apps (external-secrets.yaml, wrapped by cloud-init; external-dns.yaml, reference only)
gitops/argocd/               — ArgoCD supplementary config (BackendTrafficPolicy rate limit), managed by argocd-config.yaml
gitops/pdbs/                 — PodDisruptionBudgets for ArgoCD / cert-manager (pdbs.yaml App)
gitops/system-upgrade/       — system-upgrade-controller (remote release manifests via kustomize) + k3s upgrade Plans
gitops/tailscale-operator/   — Opt-in Tailscale operator: Application template, OAuth ExternalSecret, ProxyClass
gitops/network-policies/     — Default-deny NetworkPolicies + namespaces.yaml for the optional-feature namespaces (managed by network-policies.yaml App)
gitops/longhorn/             — Longhorn supplementary config: ingress (BasicAuth HTTPRoute), backup-target.yaml (BackupTarget CR steps + weekly RecurringJob template), taint-toleration template (worker NoSchedule), webhook-postsync/ (PostSync hook patches failurePolicy:Ignore after each Helm sync — workaround for webhook 502s via the k3s egress tunnel)
gitops/cert-manager/         — ClusterIssuer templates + ArgoCD Application template (see adoption notes)
gitops/gateway/              — Envoy Gateway config: EnvoyProxy (DaemonSet/NodePort), GatewayClass, Gateway, redirect HTTPRoute, TLS ClientTrafficPolicy
gitops/external-secrets/     — ClusterSecretStore template + example ExternalSecret CRs (enable_external_secrets)
example/         — Example module usage (+ get-kubeconfig.sh, ssh-node.sh — run from example/)
scripts/clean-oci-resources.sh   — delete every OCI resource of a cluster (KEEP_VAULT / KEEP_BUCKETS)
scripts/teardown-keep-data.sh    — destroy but keep vault + buckets, re-import them
scripts/setup-longhorn-backup.sh — manual Longhorn backup wiring (when Terraform does not own the key)
scripts/import-opensuse-aarch64.sh — import the openSUSE Leap aarch64 image as a custom image
Justfile         — Common operation recipes: just apply, just kubeconfig, just ssh worker, just teardown-keep-data, just fmt, just validate
CHANGELOG.md     — release notes; maintained by release-please from conventional commits
SECURITY.md      — supported versions + vulnerability reporting
.github/workflows/ci.yml         — CI: fmt, validate, tflint, ShellCheck, terraform-docs
.tflint.hcl / .trivyignore       — tflint rules; accepted Trivy findings (each with a justification)
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
- Both load balancers have `prevent_destroy = false` so `tofu destroy` works for full rebuilds (the NLB IP changes on rebuild — sslip.io hostnames are recomputed). Only the Vault and its key use `prevent_destroy = true`.
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
  ShellCheck runs on these files without workarounds: `# shellcheck disable=SC2154` covers vars
  exported by the prepended template header, plus two documented inline `SC2097,SC2098`
  suppressions on the `K3S_URL="" sh -s -` installer calls in `k3s-server.sh` / `k3s-agent.sh`.
- `data.tf` assembles the final script with `join("\n", [templatefile(...), file(...), ...])`.
- Ubuntu 26.04 is the default OS (`var.os_family = "ubuntu"`); 24.04 is no longer supported. openSUSE Leap is supported via `var.os_family = "opensuse"` — its bootstrap is in `files/lib/bootstrap-opensuse.sh`. Do not add Oracle Linux support.
- Standalone scripts (`scripts/`, `example/*.sh`, `gitops/update-repo-url.sh`) start with `set -euo pipefail`.
  The bootstrap files (`common.sh`, `bootstrap-*.sh`) set it for the assembled cloud-init script; the other
  `files/lib/*.sh` files only define functions and inherit it — do not add it there.

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
| ShellCheck | `just shellcheck` (same file list as `shellcheck_files` in `ci.yml`) |
| YAML lint (gitops/ + .github/workflows/) | `yamllint -d '{extends: relaxed, rules: {line-length: {max: 200}}}' gitops/ .github/workflows/` |
| actionlint | `actionlint` (GitHub Actions workflow syntax) |
| Trivy IaC scan | `trivy config . --severity HIGH,CRITICAL` (Terraform + gitops) |
| terraform-docs | fails on diff in fork PRs; same-repo PRs get an auto-commit (not Renovate's, and not on `main` — see Releases and branch protection) |

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
  scripts/clean-oci-resources.sh \
  scripts/teardown-keep-data.sh \
  scripts/import-opensuse-aarch64.sh \
  scripts/setup-longhorn-backup.sh \
  gitops/update-repo-url.sh \
  example/get-kubeconfig.sh \
  example/ssh-node.sh
yamllint -d '{extends: relaxed, rules: {line-length: {max: 200}}}' gitops/ .github/workflows/
actionlint
trivy config . --severity HIGH,CRITICAL --skip-dirs .terraform,example/.terraform
terraform-docs .
```

## Releases and branch protection

- `main` is protected by the `main` ruleset: the `terraform / …` CI checks must pass, no
  force-push, no deletion. Repository admins bypass it (direct pushes keep working); Renovate
  and other PRs only merge after CI is green.
- Releases are cut by release-please (`.github/workflows/release-please.yml`,
  `release-please-config.json`, `.release-please-manifest.json`). Conventional commits drive the
  version: `fix:` → patch, `feat:` → minor, `!` / `BREAKING CHANGE:` → major; `docs:`, `chore:`,
  `ci:` do not release. Write commit subjects as changelog entries.
- release-please keeps a `chore(main): release X.Y.Z` PR open that updates `CHANGELOG.md`,
  the manifest and `version.txt`. Merging it creates the `vX.Y.Z` tag and GitHub release.
  The PR is opened with `GITHUB_TOKEN`, so no CI runs on it: an admin merges it with the
  ruleset bypass (it only touches release metadata).
- release-please needs the repo setting *Allow GitHub Actions to create and approve pull
  requests* (Settings → Actions → General); without it the workflow fails with
  "GitHub Actions is not permitted to create or approve pull requests".
- The ruleset cannot exempt `GITHUB_TOKEN` (personal repos cannot add the GitHub Actions app as
  a bypass actor), so the terraform-docs job's README auto-commit to `main` is rejected. Renovate
  PRs skip the README update, so after merging one that changes a `vars.tf` default, run
  `terraform-docs .` (and revert the separator churn) and push the result as an admin.
- `gateway_api_version` follows Envoy Gateway: its chart re-applies the Gateway API CRDs it bundles
  (`sigs.k8s.io/gateway-api` in `envoyproxy/gateway` `go.mod`). Renovate does not automerge
  gateway-api; merge a bump only when the pinned Envoy Gateway release ships that version.
- Do not edit the release sections of `CHANGELOG.md` by hand; add context to the commit body
  instead (or edit the release PR before merging).

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

Set `KEEP_BUCKETS=true` to leave the `${CLUSTER_NAME}-terraform-state` and `${CLUSTER_NAME}-longhorn-backup`
buckets (etcd snapshots, Longhorn backups) in place. You need them to restore a rebuilt cluster. Run
`tofu state rm` on them before `tofu destroy`, and re-import them afterwards: bucket ID
`n/<namespace>/b/<name>`, lifecycle policy ID `n/<namespace>/b/<name>/l`.
The clean script also deletes the `${CLUSTER_NAME}-longhorn-backup` IAM user (with its keys) and group
(`create_longhorn_backup_user`); set `TENANCY_OCID` when `COMPARTMENT_OCID` is not the tenancy root.

Set `KEEP_VAULT=true` to leave the `${CLUSTER_NAME}-vault` vault and its secrets untouched (recommended:
the vault has `prevent_destroy`, and a deleted vault blocks the quota for 7+ days). Re-import it into
the fresh state before `tofu apply` (`tofu import 'module.<name>.oci_kms_vault.k3s[0]' <vault_ocid>`,
the key as `managementEndpoint/<mgmt_endpoint>/keys/<key_ocid>`, plus every module-managed secret).

### `scripts/teardown-keep-data.sh` — rebuild keeping vault + buckets

**When to use:** a full rebuild that must keep the Vault (key + secrets) and both buckets (etcd snapshots,
Longhorn backups). It does the `state rm` → `tofu destroy` → `clean-oci-resources.sh` (KEEP_VAULT +
KEEP_BUCKETS) → cancel deletions → `tofu import` sequence. Import IDs come from `tofu show -json`
and are saved in `$TF_DIR/.teardown-keep-data.tsv` (gitignored, no secrets). `IMPORT_ONLY=true` resumes
from it. `CLEAN_CMD` lets a wrapper add its own cleanup (e.g. Tailscale devices).

```bash
COMPARTMENT_OCID=ocid1.tenancy.oc1..xxx CLUSTER_NAME=mycluster just teardown-keep-data
```

After the rebuild the new server logs the "previous etcd snapshots exist" warning (expected — the bucket
survived). The old snapshots stay restorable until the new cluster has uploaded `etcd_snapshot_retention`
snapshots (~30 h at the defaults), because pruning spans the whole `etcd-snapshots/<cluster>/` prefix.

> **Vault quota:** OCI vaults have a 7-day minimum deletion grace period and count against the
> ~5-vault compartment limit even while `PENDING_DELETION`. If `tofu apply` fails with a vault
> quota error, wait for old vaults to fully delete or request a service limit increase.

---

## What NOT to do

- Do not add paid OCI resources (compute shapes other than A1.Flex, extra NLBs, etc.)
- Do not add Oracle Linux support — Ubuntu 26.04 LTS (default) and openSUSE Leap (via `var.os_family`) are the two supported OS families
- Do not remove `lifecycle { prevent_destroy = true }` from the Vault or its key
- Do not hardcode secrets, OCIDs, or credentials anywhere
- Do not remove the `# renovate:` comments on version variables
- Do not commit `example/terraform.tfvars` (it is gitignored; `.tfvars.example` is the template)
- Do not break the `terraform validate` step — `server-vars.sh.tpl` / `agent-vars.sh.tpl` vars must match what `data.tf` passes
- **Do not suggest terminating TLS at the OCI load balancer** — the public-facing LB is the OCI NLB (`nlb.tf`), which operates at L4 TCP only (`protocol = "TCP"`) and cannot inspect or terminate TLS. The one free OCI Flexible LB allocation (L7, TLS-capable) is consumed by the internal kubeapi LB (`lb.tf`). TLS must be terminated at Envoy Gateway. cert-manager + Let's Encrypt handles certificate issuance and renewal automatically.
- **Do not add nginx or other ingress controllers** — Envoy Gateway (Gateway API) is the ingress implementation. All HTTP/HTTPS routing uses standard `HTTPRoute`, `Gateway`, and `GatewayClass` resources.
- **Do not re-add `control-plane:NoSchedule` taints** — cloud-init removes these taints after cluster init so user workloads schedule across both nodes. With only 1 worker, keeping the taints makes the worker a single point of failure for all workloads. All nodes are identically sized; etcd and ordinary user workloads coexist — but see "Server disk latency" below: IO-heavy batch jobs must stay off the server.
- **Do not add UFW or any iptables-front-end** to nodes. k3s manages iptables directly via flannel;
  adding ufw would flush k3s's rules on `ufw enable` and break pod networking. OCI NSGs provide
  the security boundary at the hypervisor level, independent of the OS firewall. UFW's default
  `22/tcp LIMIT` also rate-limits the NLB SSH health checks from the subnet, marking backends
  CRITICAL. **fail2ban is fine** (use an nftables banaction, not `ufw`, and ignore the VCN CIDR).
- **Do not add `pkill containerd-shim` (or any shim-killing `ExecStopPost`) to the k3s unit.**
  k3s uses `KillMode=process` so pods survive a k3s restart; killing the shims turns every
  k3s restart (including a leader-election-lost exit) into a restart of every pod on the node.
- **Vault uses `DEFAULT` type and `SOFTWARE` protection only** — `VIRTUAL_PRIVATE` vault type and `HSM` protection mode are NOT Always Free. `vault_type = "DEFAULT"` (shared vault) + `protection_mode = "SOFTWARE"` are entirely free. The 150-secret limit covers the 2–9 cluster secrets many times over. Never change the vault type or protection mode without verifying cost.
- **Vault and key have `prevent_destroy = true`** — OCI DEFAULT vaults have a low per-tenancy limit and take a minimum of 7 days to fully delete (the `PENDING_DELETION` state counts against quota). `prevent_destroy` keeps the vault alive across `tofu destroy`/`tofu apply` cycles. If you genuinely need to delete the vault, remove the `lifecycle` block or run `tofu state rm` first.
- **Do not add an nginx stream proxy** back. The OCI NLB routes directly to Envoy Gateway NodePorts
  (`is_preserve_source = true` preserves real client IPs transparently). An extra nginx hop
  adds latency and complexity with no benefit.
- **Do not reduce `boot_volume_size_in_gbs` below 50 GB** — OCI requires ≥ 50 GB for boot
  volumes on all shapes (A1.Flex and E2.1.Micro alike). The default 2 × 100 GB = 200 GB exactly
  fills the Always Free block storage limit. Do not shrink it to "save" storage: boot volume
  IOPS/throughput scale with size, and etcd fsync latency is the server's main stability limit.
  Do not suggest 47 GB as an optimisation — it is not valid.

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
- HTTP-01 ACME challenges use `gatewayHTTPRoute` solver (cert-manager Gateway API integration). cert-manager is installed with both `--feature-gates=ExperimentalGatewayAPISupport=true` **and** `config.enableGatewayAPI=true` (via `config.apiVersion` + `config.kind` + `config.enableGatewayAPI` Helm values). Both are required since cert-manager v1.15 — the feature gate alone is not sufficient to enable the `gatewayHTTPRoute` HTTP-01 solver.
- TLS certificates live in the `envoy-gateway-system` namespace (same as the Gateway) so no `ReferenceGrant` is needed.
- BasicAuth for Longhorn UI uses Envoy Gateway `SecurityPolicy` with `.htpasswd` Secret — same security, standard API.
- Do not change `envoyDaemonSet` back to `envoyDeployment` — this would reintroduce a single-pod SPOF for all HTTP/HTTPS traffic.

### Longhorn storage
- Replica count is **explicitly pinned to 2** in `gitops/apps/longhorn.yaml` via `defaultSettings.defaultReplicaCount=2` and `persistence.defaultClassReplicaCount=2`. Do not rely on the upstream chart default. With 2 nodes and hard replica anti-affinity, a third replica can never be scheduled — **do not increase it**.
- Longhorn is managed entirely by ArgoCD (`gitops/apps/longhorn.yaml`). Cloud-init does NOT install Longhorn.
- With 2 nodes and 2 replicas, either node can be lost without PVC data loss (one replica per node). There is no 3-replica StorageClass — it would be unschedulable. Off-cluster protection comes from Longhorn backups (`enable_longhorn_backup`).
- etcd is single-node: losing the server's boot volume means restoring from an etcd snapshot, regardless of Longhorn replicas.

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
  then copy `application-template.yaml` to `gitops/apps/cert-manager-issuers.yaml`
  (`gitops/apps/cert-manager.yaml` is the cert-manager Helm release — do not overwrite it).
- Do NOT place the template in `gitops/apps/` as-is — it contains `changeme@example.com`.

### Cloud-init structure (`files/`)
- **Separation of concerns**: `server-vars.sh.tpl` and `agent-vars.sh.tpl` are the ONLY files
  with Terraform `${var}` interpolation. All `files/lib/*.sh` are pure bash.
- **Assembly**: `data.tf` uses `join("\n", [templatefile(vars.tpl), bootstrap-{ubuntu,opensuse}.sh, file(lib/common.sh), ...])` to
  produce a single cloud-init script. The OS-specific bootstrap file is selected by `var.os_family`. The rendered vars header is prepended, making all
  `export KEY="value"` statements available to the lib scripts at runtime.
- **Bootstrap script split**: `k3s-bootstrap.sh` is a ~60-line orchestrator. Concerns live in
  focused sub-scripts (all pure bash, concatenated in order before `k3s-bootstrap.sh` in `data.tf`):
  - `k3s-secrets.sh` — `pre_create_secrets()`: Longhorn, MySQL, Cloudflare
  - `k3s-cert-manager.sh` — `install_certmanager()`: cert-manager Helm + ClusterIssuers
  - `k3s-external-secrets.sh` — `install_external_secrets()`: ESO Helm + ClusterSecretStore
  - `k3s-argocd.sh` — `install_argocd()`, `create_dockerhub_secret()`, `create_optional_app()`,
    `create_optional_apps()`, `configure_app_ingress()`,
    `configure_argocd_ingress()`, `configure_longhorn_ingress()`
  - `k3s-bootstrap.sh` — `install_gateway_api_crds()` + `run_bootstrap()` (calls the above)
- **GitOps-first**: cloud-init only bootstraps what ArgoCD cannot self-manage:
  - Gateway API CRDs (must exist before ArgoCD syncs `gateway-config` app)
  - cert-manager Helm + ClusterIssuers (email is a runtime Terraform var, not static git)
  - ArgoCD Helm + App of Apps bootstrap
  - External Secrets Operator Helm + ClusterSecretStore (conditional, vault_ocid is runtime)
  - Pre-create Kubernetes Secrets with runtime values (passwords, endpoints)
  - Hostname-specific HTTPS Gateway listener + TLS Certificate + HTTPRoute (NLB IP is runtime; see `configure_argocd_ingress()` in `k3s-argocd.sh` and the "Hostname-specific HTTPS resources" section in Deploying web apps)
- **Managed by ArgoCD, NOT cloud-init**: Envoy Gateway, Longhorn, kured,
  system-upgrade-controller — all in `gitops/apps/*.yaml`. The opt-in components live in
  `gitops/optional/` and get an Application only when their flag is on: ESO through the
  `optional-external-secrets` wrapper, external-dns through `create_external_dns_app()`.
- **Removed vars**: `kured_start_time`, `kured_end_time`, `kured_reboot_days`, `kured_chart_version`,
  `longhorn_chart_version`, `envoy_gateway_chart_version`, `external_dns_chart_version` were
  removed from `vars.tf`. Configure kured via `gitops/apps/kured.yaml` directly.
- **Shared cloud-init vars**: `local.k3s_common_cloud_init_vars` in `locals.tf` holds the eight
  vars shared by both server and agent (`k3s_version`, `k3s_subnet`, `k3s_token`, `k3s_url`,
  `kube_api_port`, `vault_secret_id_k3s_token`, `ssh_host_key_private_b64`, `ssh_host_key_public`). The server templatefile call uses `merge(local.k3s_common_cloud_init_vars, {...server-only...})`; the agent call passes the local directly.
- **Flannel interface resolution**: `resolve_flannel_params()` in `common.sh` sets `LOCAL_IP` and
  `FLANNEL_IFACE` (exported) when `K3S_SUBNET` is not `default_route_table`. Called by both
  `install_k3s_server()` and `install_k3s_agent()`; server adds `--advertise-address` too.
- **ShellCheck**: `# shellcheck disable=SC2154` at the top of each lib/ file covers exported vars
  from the prepended template header. The only other suppressions are the two inline
  `SC2097,SC2098` ones on the k3s installer calls (intentional `K3S_URL=""` env override).

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
- CI (`terraform-docs` job) auto-commits README drift on same-repo PR branches; on `main` the
  ruleset rejects that push, so regenerate locally (see Releases and branch protection).
- Run `terraform-docs .` locally before pushing to avoid an extra CI commit.
- Config is in `.terraform-docs.yml` (inject mode, sort by name).

### Tailscale operator (`enable_tailscale`)
- Controlled by `enable_tailscale` variable (default: `false`). Requires `enable_vault = true`.
- Stores two Vault secrets: `${cluster_name}-tailscale-oauth-client-id` and `${cluster_name}-tailscale-client-secret` (sic — not `-oauth-client-secret`).
- Pre-requisite: create an OAuth client at https://login.tailscale.com/admin/settings/oauth — scope `Devices → Write (devices:core:write)`, allowed tag `tag:k8s-operator`. Scopes cannot be changed after creation.
- `tailscale_vault_secret_names` output shows the generated secret names; reference these in `platform/<cluster>/tailscale-operator/oauth-secret.yaml` ExternalSecret.
- The Tailscale operator Helm chart + RBAC is NOT bootstrapped by cloud-init — it is deployed by ArgoCD using the manifests in the consumer repo (`clusters/<cluster>/tailscale-operator.yaml`).
- Using Tailscale LoadBalancer Services: add `loadBalancerClass: tailscale` + `tailscale.com/hostname: <name>` annotation; the operator creates a proxy pod and registers `<name>.<tailnet>.ts.net`.
- **Tailscale VIP IPs are dynamic** — the IP assigned to a Tailscale LoadBalancer Service changes on every cluster rebuild (new proxy pod, new Tailscale identity). Consumer repos must not hardcode these IPs in DNS or config. Instead, read the IP after deploy (`kubectl get svc -o jsonpath='{.status.loadBalancer.ingress[*].ip}'`) and update DNS records programmatically as a post-deploy step.

### OCI Vault (`vault.tf`)
- Controlled by `enable_vault` variable (default: `true`).
- Uses `vault_type = "DEFAULT"` (shared vault, free). `VIRTUAL_PRIVATE` vaults cost money — never use that type.
- Key uses `protection_mode = "SOFTWARE"` (free). HSM-protected keys are NOT free.
- Stores 2–9 secrets, all named `${cluster_name}-<suffix>` (same table as the README's "OCI Vault secrets"):
  | Suffix | Created when |
  |---|---|
  | `k3s-token`, `longhorn-ui-password` | always (`oci_vault_secret.cluster` for_each) |
  | `dockerhub-password` | `dockerhub_password != ""` |
  | `gitops-ssh-key` / `gitops-https-token` | `gitops_ssh_private_key` / `gitops_https_token` set |
  | `cloudflare-api-token` | `cloudflare_api_token != null` |
  | `tailscale-oauth-client-id`, `tailscale-client-secret` | `enable_tailscale = true` |
  | `longhorn-backup-secret-key` | Terraform owns the key (`create_longhorn_backup_user` or `user_ocid`) |
- Cloud-init fetches secrets at boot via `oci secrets secret-bundle get-secret-bundle` with `OCI_CLI_AUTH=instance_principal`.
- When `enable_vault = false`, the plaintext values are exported by `server-vars.sh.tpl` / `agent-vars.sh.tpl` as `K3S_TOKEN_PLAIN`, `LONGHORN_UI_PASSWORD_PLAIN`, `DOCKERHUB_PASSWORD`; the lib scripts use them as fallback.
- The IAM policy uses `concat()` to add `read secret-family` only when `enable_vault = true`.
- Agent script (`files/lib/k3s-agent.sh`) installs OCI CLI and fetches k3s_token from Vault when `VAULT_SECRET_ID_K3S_TOKEN` is non-empty.

### Accepted plaintext user-data constraints

When `enable_vault = true`, most sensitive values are blanked from instance user-data and fetched
from Vault at boot. The following three values remain in plaintext user-data by design:

- **SSH host private key** (`SSH_HOST_KEY_PRIVATE_B64`): Required by `setup_shared_ssh_host_key()`
  in `common.sh` inside `bootstrap()`, which runs before the OCI CLI or IAM are available.
  It is a chicken-and-egg dependency — the key cannot be fetched from Vault because OCI CLI
  isn't installed yet. This is an accepted constraint; the SSH host key is not a cluster
  administrative secret.
- **MySQL admin password** (`MYSQL_ADMIN_PASSWORD`): Only present when `enable_mysql = true`.
  The MySQL DB system is in the private subnet with no internet path. The password is also
  already present in a Kubernetes Secret cluster-wide. Risk accepted.
- **Longhorn backup S3 key** (`LONGHORN_BACKUP_SECRET_KEY`): Only present when Terraform owns
  the key (`create_longhorn_backup_user = true` or `var.user_ocid` set) **and** `enable_vault = false`.
  With `enable_vault = true` the secret half is stored as `${cluster_name}-longhorn-backup-secret-key`
  (`oci_vault_secret.longhorn_backup_secret_key`) and fetched by `pre_create_secrets()` via
  `VAULT_SECRET_ID_LONGHORN_BACKUP_KEY`; only the (non-secret) access key ID stays in user-data.
  A Customer Secret Key is **not** bucket-scoped — it carries every permission of its user.
  `create_longhorn_backup_user` creates a user whose group policy only allows `read buckets` /
  `manage objects` `where target.bucket.name='<cluster>-longhorn-backup'` and whose capabilities
  allow nothing but Customer Secret Keys. If you use `user_ocid` instead, point it at such a user, never at an admin.

### Boot Volume Backups (`backup.tf`)
- Controlled by `enable_backup` variable (default: `true`).
- Creates a custom `oci_core_volume_backup_policy` with weekly full backups, 1-week retention.
- Assigns the policy to all server boot volumes (`data.oci_core_instance.k3s_servers[*].boot_volume_id`) and the standalone worker boot volume.
- With 2 nodes and 1-week retention there are at most 2 active backups — within the 5-backup Always Free limit.
- Do NOT increase retention or frequency beyond 1-week/weekly without exceeding the free limit.

### Object Storage Buckets (`objectstorage.tf`)
- `data.oci_objectstorage_namespace.k3s` is created when **either** `enable_object_storage_state` or `enable_longhorn_backup` is true — both buckets share it.
- **Terraform state bucket** (`enable_object_storage_state = true`): versioned, `NoPublicAccess`, name `${cluster_name}-terraform-state`. Despite the name it holds etcd snapshots and the leader lock. **Do not recommend storing Terraform state in it**: nodes have `manage objects` on it, the state contains every cluster secret, and destroy/clean delete it. The README documents a separate, module-external state bucket configured via a gitignored `backend_override.tf`.
- **Longhorn backup bucket** (`enable_longhorn_backup = true`): versioned, `NoPublicAccess`, name `${cluster_name}-longhorn-backup`. With `create_longhorn_backup_user = true` (resources in `iam.tf`: user, capabilities, group, membership, policy — all `${cluster_name}-longhorn-backup`) cloud-init wires everything: `longhorn-backup-secret` with `AWS_ENDPOINTS`, the `backuptargets.longhorn.io/default` CR, and the `daily-backup` (`longhorn_backup_schedule`, `longhorn_backup_retain`) + `weekly-snapshot-cleanup` RecurringJobs via SSA (`setup_longhorn_backup_target()` in `k3s-secrets.sh`). Otherwise the `longhorn_backup_setup` output prints the three manual steps (Customer Secret Key → `longhorn-backup-secret` with `AWS_ENDPOINTS` → patch the `backuptargets.longhorn.io/default` CR). Longhorn ≥ 1.8 has no `backup-target` Setting — always use the BackupTarget CR. Nodes need no IAM grant on this bucket (Longhorn authenticates with the Customer Secret Key).
- Both buckets share the Always Free Object Storage allowance — 20 GB on Free Tier accounts, but only **10 GB once the tenancy is upgraded to Pay As You Go**. Both buckets have a lifecycle rule purging noncurrent versions after 2 days; without it, pruned etcd snapshots kept being billed. Longhorn backup bucket uses no versioning for actual backup blobs (Longhorn manages its own retention), but the bucket resource has versioning enabled for accidental-delete protection.
- Users need OCI Customer Secret Keys (S3 credentials) to use either bucket. Keys inherit all rights of their user, so keys placed in the cluster must belong to a bucket-scoped service user.

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

`route_name` is optional and defaults to `<service>`. Set it explicitly when the gitops HTTPRoute file uses a different name from the backend service (e.g. `longhorn` vs `longhorn-frontend`).

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
6. Call it from `run_bootstrap()` in `k3s-bootstrap.sh`. Ingress setup is non-fatal (the
   cluster works without it), so follow the existing pattern and only warn:
   ```bash
   configure_myapp_ingress || echo "WARNING: configure_myapp_ingress failed — cluster is functional; ingress can be retried via cloud-init."
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
- `local.argocd_hostname` auto-computes `argocd.<nlb-ip>.sslip.io` (or uses `var.argocd_hostname` if set).
- `local.longhorn_hostname` uses `var.longhorn_hostname` (no sslip.io fallback — Longhorn UI is opt-in).
- `files/server-vars.sh.tpl` exports `ARGOCD_HOSTNAME`, `LONGHORN_HOSTNAME`.
- `files/lib/k3s-argocd.sh:configure_app_ingress(hostname namespace service port listener_name)` is the generic helper.
  - Creates the Gateway HTTPS listener (SSA, field-manager=cloud-init-bootstrap)
  - Creates the cert-manager Certificate in `envoy-gateway-system`
  - Creates the app HTTPRoute in the app namespace (SSA, field-manager=cloud-init-bootstrap)
- `configure_argocd_ingress()`, `configure_longhorn_ingress()` each call the generic helper.
- `configure_longhorn_ingress()` additionally applies the `SecurityPolicy` for BasicAuth.
- `gitops/gateway/gateway.yaml` has ONLY the `http` listener (ArgoCD owns it via SSA).
- The ArgoCD HTTPRoute is defined WITHOUT `hostnames` (ArgoCD owns all fields except `spec.hostnames`, which cloud-init-bootstrap owns).

**SSA field-manager ownership prevents ArgoCD from clearing cloud-init patches**

Gateway API's `spec.listeners` is a `x-kubernetes-list-map-keys: [name]` list — SSA treats it as a named map and merges by the `name` key. Each SSA manager owns the entries it applied:
- `argocd-controller` owns `spec.listeners[name=http]` (applied from gateway.yaml)
- `cloud-init-bootstrap` owns `spec.listeners[name=https-argocd]` (applied by configure_argocd_ingress)
When ArgoCD syncs gateway.yaml (without `https-argocd`), it only owns `http` and never touches `https-argocd`. The `ignoreDifferences: /spec/listeners` in gateway-config ArgoCD Application suppresses OutOfSync warnings.

Similarly, `spec.hostnames` in the ArgoCD HTTPRoute is owned by `cloud-init-bootstrap` (via `kubectl apply --server-side --field-manager=cloud-init-bootstrap --force-conflicts`). ArgoCD's SSA apply (without `hostnames` in the manifest) doesn't claim or clear the field.

**Do NOT use CSA (kubectl apply without --server-side) to patch ArgoCD-managed resources.** CSA sets the `kubectl.kubernetes.io/last-applied-configuration` annotation, which confuses ArgoCD's 3-way merge on the next sync. Always use SSA with a custom field-manager for cloud-init patches to ArgoCD-managed resources.

**gateway-config MUST use ServerSideApply=true** to avoid `resourceVersion: 0` errors. Without SSA, ArgoCD's CSA apply with `RespectIgnoreDifferences` strips `spec.listeners` from the patch payload, causing a malformed UPDATE request to fail validation.

### Feature flag co-dependencies (`checks.tf`)
Terraform 1.9+ `check {}` blocks in `checks.tf` catch invalid feature flag combinations at plan time
before any OCI API call is made:
- `enable_external_secrets = true` requires `enable_vault = true` and `region != null`
- `enable_dns01_challenge = true` requires `cloudflare_api_token != null`
- `enable_external_dns = true` requires `cloudflare_api_token`, `cloudflare_zone_id`, and `external_dns_domain_filter`
- `enable_tailscale = true` requires `enable_vault = true` and both `tailscale_oauth_client_id` and `tailscale_oauth_client_secret` set
- `create_longhorn_backup_user = true` requires `enable_longhorn_backup = true`, and is mutually exclusive with `user_ocid`
- automatic Longhorn backup wiring (`create_longhorn_backup_user` or `user_ocid`) requires `region != null`

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
- `k3s_server_pool_size`: must be odd positive integer (etcd quorum; Always Free only fits 1)
- `standalone_worker_fault_domain`: `FAULT-DOMAIN-[1-3]` or null

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
- Cloud-init installs `/usr/local/bin/etcd-snapshot-upload.sh` + cron job on every server (every 6h, at :00–:04).
- k3s's built-in snapshot schedule is moved to `15 */12 * * *` (`--etcd-snapshot-schedule-cron`) — the default `0 */12 * * *` collides with the upload cron and fails with "snapshot save already in progress". Do not align the two schedules.
- Snapshots are uploaded to `${cluster_name}-terraform-state` bucket under `etcd-snapshots/${CLUSTER_NAME}/<hostname>/` using OCI CLI instance_principal auth — **no Customer Secret Keys required**.
- Pruning keeps the newest `etcd_snapshot_retention` objects across the whole `etcd-snapshots/${CLUSTER_NAME}/` prefix (not per hostname), so prefixes of replaced servers are cleaned up too. There is deliberately no age-based expiry rule: it would delete the last restore points of a cluster that has been down for a while.
- When a single server bootstraps a fresh cluster (`--cluster-init`) and snapshots already exist in the bucket, `_warn_if_previous_snapshots_exist()` logs a loud WARNING with the `k3s server --cluster-reset --cluster-reset-restore-path` restore steps — a replaced server otherwise silently starts an empty cluster.
- IAM policy `manage objects in bucket ${cluster_name}-terraform-state` (added in `iam.tf`) enables this.
- Retention is configurable via `etcd_snapshot_retention` (default: 5 snapshots).
- These snapshots are the primary recovery path for split-brain and etcd quorum loss. See `README.md#split-brain-recovery`.

### Atomic leader lock (`--cluster-init` safety)
- `claim_first_server_lock()` in `files/lib/k3s-server.sh` uses **`oci os object put --no-overwrite`** to OCI Object Storage before running `--cluster-init`. `--no-overwrite` maps to server-side If-None-Match: * and is the correct native atomic conditional-create primitive — it exits non-zero when the object already exists. **Do NOT use `--if-none-match` (not a valid CLI flag) or `oci raw-request --request-body-file` (also not a valid flag).**
- Lock object: `cluster-init-lock` in the `${cluster_name}-terraform-state` bucket.
- If the lock already exists and the holder's instance is still RUNNING, the node switches to join mode (resolving the holder's IP from `LOCK_HOLDER_OCID`) instead of aborting with exit 1 — this handles TIMECREATED-tie scenarios where two nodes elect themselves simultaneously.
- Stale locks (different cluster name, or holder instance terminated) are automatically overwritten. A cluster-reachability probe (`_probe_existing_cluster()`) prevents re-init if a live cluster is still reachable after reclaim.
- On a deliberate full rebuild (destroy + apply), delete the stale lock: `oci os object delete --bucket-name ${cluster_name}-terraform-state --name cluster-init-lock --force`.
- When Object Storage is not configured (`CLUSTER_LOCK_BUCKET` empty), the lock is skipped and the TIMECREATED election alone determines the first server.

### Fail-closed split-brain fallback
- `install_k3s_server()` in `k3s-server.sh`: when `IS_FIRST_SERVER=false`, joining nodes **abort** if `FIRST_SERVER_IP` is empty (OCI API failure during election), instead of falling back to `K3S_URL` (the internal LB).
- **Do NOT reintroduce `${FIRST_SERVER_IP:-${K3S_URL}}`** — that fallback is the exact path that caused the documented split-brain issues. The internal LB routes to UNKNOWN-state backends for ~30s after creation, which can route a joining server's bootstrap to another uninitialised node.

### Longhorn replica count
- Default replica count is **2** — one replica per node on the 2-node topology. **Do not increase it**: a third replica is unschedulable with 2 nodes.
- Do not add a PodDisruptionBudget for `longhorn-manager`: it is a DaemonSet (drains skip it), and `minAvailable: 2` on 2 nodes allows zero disruptions.

### Longhorn sync-wave
- `gitops/apps/longhorn.yaml` has `argocd.argoproj.io/sync-wave: "-1"` — **do not remove**. This ensures Longhorn converges and its StorageClass is ready before any wave-0 app that provisions PVCs. Without it, PVCs from those apps sit Pending for 10-30 minutes on first boot.

### Upgrade plan PDB behaviour
- `gitops/system-upgrade/plans.yaml` does NOT use `disableEviction: true` — **do not add it back**. With `disableEviction`, PDBs are bypassed during upgrade drains. Serialization comes from `concurrency: 1`, the kured lock, and Longhorn's auto-generated instance-manager PDBs.

### Server disk latency (main failure mode)
- etcd lives on the server's boot volume, shared with container images, Longhorn replicas and logs. When
  another workload saturates the volume, etcd logs `slow fdatasync` (seconds), apiserver requests stall,
  and k3s exits with `leaderelection lost for k3s`; systemd restarts it. Observed on a live cluster when
  IO-heavy CronJobs (Renovate, CI runners) were scheduled on the server.
- Mitigations in this module: 100 GB boot volumes (2× the IOPS of 50 GB), `--leader-elect=false` for
  the single-server controller-manager/scheduler, kubelet image GC at 70 %/55 % instead of 85 %/80 %,
  and no shim-killing ExecStopPost (a k3s restart no longer restarts every pod).
- Consumer guidance: pin IO-heavy batch workloads (CI runners, Renovate, image builds) off the
  server with **required** node affinity `node-role.kubernetes.io/control-plane DoesNotExist`.
  `preferred` affinity is not enough — when the worker is full the scheduler falls back to the server.
- Do not switch to the SQLite datastore to "fix" this: SQLite's WAL fsync suffers the same latency,
  and you lose `k3s etcd-snapshot` and the snapshot upload path.

### Internal LB health check
- `lb.tf` uses a **TCP** health check on the kubeapi port. The OCI flexible LB rejects `HTTPS` as a health-check protocol ("No enum constant for HTTPS"), and a plaintext `HTTP` probe can never pass against the TLS-only apiserver. **Do not change it to HTTP.** TCP cannot detect a server whose etcd is dead but whose port is open — irrelevant with a single server, but worth knowing if the pool ever grows.

### First-server bootstrap SPOF (accepted constraint)
- If the TIMECREATED-oldest server crashes or hangs **after** the OCI instance reaches RUNNING
  state but **before** its apiserver is reachable (i.e. during the `install_k3s_server()` window),
  joining servers wait 30 minutes then exit 1. OCI instance pools do not auto-replace a RUNNING
  instance whose cloud-init hung.
- **Manual recovery:** In the OCI Console, terminate the hung node. The instance pool will
  replace it. With the single-server pool the replacement finds the lock held by a terminated
  instance, reclaims it and runs `--cluster-init` (restore etcd from a snapshot if the old
  server had data — see the etcd Snapshots section). If that fails, rebuild with
  `just teardown-keep-data`.
- This window is narrow (typically 2–4 min) and self-correcting for most transient OCI API
  failures (cloud-init retries internally). Do not add a "promote next-oldest if leader IP
  never answers" fallback without careful analysis — it reintroduces split-brain risk.

### Stale leader-lock reclaim is non-atomic (accepted constraint)
- `claim_first_server_lock()` reclaims a stale lock (different cluster name, or terminated
  holder) with an unconditional `--force` PUT, not a CAS (`--if-match <etag>`) PUT.
- A strictly correct implementation would use `oci os object head` to read the current etag,
  then `oci os object put --if-match <etag>` — failing if another node already reclaimed.
- In practice, the deterministic `sort_by(["time-created", .id])` election means exactly one
  node reaches the reclaim path, making simultaneous reclaim essentially impossible.
- Do not add CAS reclaim unless you also add the corresponding `os object head` call and a
  retry loop — a partial implementation would be more fragile than the current approach.

### Nodes hold `manage objects` on Terraform state bucket (accepted constraint)
- `iam.tf` grants `manage objects` (including delete) on the `${cluster_name}-terraform-state`
  bucket so cloud-init can write etcd snapshots and the leader lock.
- The same bucket stores the Terraform state file. A compromised node can overwrite or delete
  the state. Bucket versioning (`objectstorage.tf`) provides recovery — old versions are
  retained and can be restored via the OCI Console or CLI.
- A 2-bucket Always Free allocation (state + Longhorn backup) makes per-purpose IAM scoping
  impossible without exceeding the budget. Document this if operating in a high-threat environment.

### ArgoCD is publicly reachable by default (accepted constraint)
- `configure_argocd_ingress()` in `k3s-argocd.sh` runs
  unconditionally, creating an sslip.io HTTPS hostname derived from the NLB IP.
- The ArgoCD UI is reachable from the internet. Mitigations in place: TLS (cert-manager/Let's Encrypt),
  random admin password (output only to Terraform state), ArgoCD RBAC.
- To restrict access: add an Envoy `SecurityPolicy` (Gateway API ExtAuth or IP-based allow-list)
  on the ArgoCD HTTPRoute, or set `var.my_public_ip_cidr` and add an NSG rule that
  limits NLB HTTP/HTTPS to your IP. Set `var.argocd_hostname = null` to skip the ArgoCD ingress.
