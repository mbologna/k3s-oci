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
| OS | Ubuntu LTS (aarch64, `var.ubuntu_version`, default 26.04) — default. openSUSE Leap (aarch64, `var.opensuse_leap_version`) via `var.os_family = "opensuse"` |
| Kubernetes | k3s (latest resolved at plan time) |
| Ingress | Traefik (Kubernetes Ingress + Traefik Middlewares; since v2.0.0, Envoy Gateway before) |
| Logging | OCI Unified Logging (optional) |
| Storage | Longhorn |
| GitOps | ArgoCD (Image Updater opt-in: `gitops/optional/`) |
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
| Budgets | Free | 1 tenancy-wide monthly budget + 3 alert rules (`budget_alert_email`, opt-in) |

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
iam.tf           — Dynamic Group (compartment-scoped — tag matching breaks instance_principal) and Policy (log-content, read secret-bundles of the boot secrets — or secret-family for an instance_principal ESO store — state-bucket objects); Longhorn backup service user/group/policy (create_longhorn_backup_user)
logging.tf       — OCI Log Group, Log, Unified Agent Configuration (enabled via enable_oci_logging)
compute.tf       — Instance pool (servers), pool (workers), standalone extra worker
lb.tf            — Internal Flexible LB (kubeapi endpoint for agents; TCP health check)
nlb.tf           — Public Network LB (HTTP/HTTPS ingress); backend sets/listeners use for_each over nlb_web_protocols local
backup.tf        — Custom weekly backup policy + assignments for all node boot volumes (enable_backup)
budget.tf        — Tenancy-wide monthly OCI budget with 50%/100% actual and 100% forecast email alerts (budget_alert_email, opt-in)
vault.tf         — OCI Vault (DEFAULT type, SOFTWARE key) + 2–9 cluster secrets (full list in the OCI Vault section)
objectstorage.tf — Versioned buckets: <cluster>-terraform-state (etcd snapshots + leader lock, NOT tofu state; enable_object_storage_state) and <cluster>-longhorn-backup (enable_longhorn_backup), each with a noncurrent-version lifecycle rule
bastion.tf       — OCI Bastion Service (managed, no VM; enable_bastion)
mysql.tf         — MySQL HeatWave DB system in private subnet (enable_mysql)
output.tf        — Outputs (IPs, k3s_token, longhorn_ui_credentials, argocd_initial_password_hint, oci_log_group_id, terraform_state_backend, mysql_endpoint, vault_id, tailscale_vault_secret_names)
files/server-vars.sh.tpl          — cloud-init header for servers: ONLY file with Terraform ${var} syntax
files/agent-vars.sh.tpl           — cloud-init header for agents: ONLY file with Terraform ${var} syntax
files/kubeconfig-hint-bastion.tpl     — kubeconfig retrieval instructions when bastion is enabled
files/kubeconfig-hint-no-bastion.tpl  — kubeconfig retrieval instructions when bastion is disabled
files/lib/common.sh               — pure bash: OS-agnostic helpers: setup_shared_ssh_host_key(), configure_longhorn_prereqs() (iscsid timeout, multipathd blacklist), setup_k3s_memory_protection() (MemoryLow/GOMEMLIMIT drop-in, fwupd masked), setup_flannel_fdb_fix(), install_oci_cli(), install_helm(), resolve_flannel_params()
files/lib/bootstrap-ubuntu.sh    — pure bash: Ubuntu bootstrap: wait_apt_lock(), bootstrap(), configure_unattended_upgrades() (apt, unattended-upgrades, needrestart)
files/lib/bootstrap-opensuse.sh  — pure bash: openSUSE bootstrap: bootstrap(), configure_unattended_upgrades() (zypper, /usr/local/sbin/zypper-patch-with-sentinel, kured sentinel)
files/lib/k3s-server.sh           — pure bash: first-server election, custom CA seeding (seed_custom_ca), k3s install, main entry point
files/lib/k3s-bootstrap.sh        — pure bash: orchestrator — run_bootstrap()
files/lib/k3s-secrets.sh          — pure bash: pre_create_secrets() — Longhorn, MySQL, Cloudflare secrets
files/lib/k3s-cert-manager.sh     — pure bash: install_certmanager() — cert-manager Helm + ClusterIssuers
files/lib/k3s-external-secrets.sh — pure bash: install_external_secrets() — ESO Helm + ClusterSecretStore
files/lib/k3s-argocd.sh           — pure bash: install_argocd(), create_dockerhub_secret(), create_optional_app(),
                                    create_optional_apps(), create_external_dns_app(), configure_app_ingress(),
                                    configure_argocd_ingress(), configure_longhorn_ingress()
files/lib/k3s-agent.sh            — pure bash: k3s agent install, main entry point
gitops/apps/                 — ArgoCD Application manifests (App of Apps pattern)
gitops/optional/             — Opt-in Applications outside the App of Apps (external-secrets.yaml, wrapped by cloud-init; external-dns.yaml, reference only; argocd-image-updater.yaml, copy to gitops/apps/ to install)
gitops/argocd/               — ArgoCD supplementary config (BackendTrafficPolicy rate limit), managed by argocd-config.yaml
gitops/pdbs/                 — PodDisruptionBudgets for ArgoCD / cert-manager (pdbs.yaml App)
gitops/coredns/              — HPA pinning k3s's CoreDNS at 2 replicas, one per node (coredns.yaml App)
gitops/priority-classes/     — PriorityClasses platform-critical (cert-manager) and worker-pinned (jobs required on the worker); priority-classes.yaml App, sync wave -2
gitops/node-cordon-alert/    — Opt-in CronJob: webhook alert when a node stays cordoned 25+ min (application-template.yaml; needs a webhook Secret)
gitops/system-upgrade/       — system-upgrade-controller (remote release manifests via kustomize) + k3s upgrade Plans
gitops/tailscale-operator/   — Opt-in Tailscale operator: Application template, OAuth ExternalSecret, ProxyClass
gitops/network-policies/     — Default-deny NetworkPolicies, namespaces.yaml (optional-feature namespaces + Pod Security labels) and token-less default ServiceAccounts (managed by network-policies.yaml App)
gitops/longhorn/             — Longhorn supplementary config: ingress template (Ingress + basicAuth Middleware), backup-target.yaml (BackupTarget CR steps + weekly RecurringJob template), taint-toleration template (worker NoSchedule)
gitops/cert-manager/         — ClusterIssuer templates + ArgoCD Application template (see adoption notes)
gitops/external-secrets/     — ClusterSecretStore template + example ExternalSecret CRs (enable_external_secrets)
example/         — Example module usage (+ get-kubeconfig.sh, ssh-node.sh — run from example/; backend_override.tf.example for a module-external state bucket)
scripts/clean-oci-resources.sh   — delete every OCI resource of a cluster (KEEP_VAULT / KEEP_BUCKETS)
scripts/teardown-keep-data.sh    — destroy but keep vault + buckets, re-import them
scripts/setup-longhorn-backup.sh — manual Longhorn backup wiring (when Terraform does not own the key)
scripts/k3s-ca-export.sh         — copy the running cluster's CA into the bundle k3s_ca_vault_secret_id expects (VAULT=true stores it as <cluster>-k3s-ca)
scripts/pre-teardown-backup.sh   — fresh etcd snapshot upload + Longhorn backup of every volume (PRE_BACKUP=true in teardown-keep-data.sh)
scripts/longhorn-restore.sh      — after a rebuild, restore each Longhorn PVC from its newest backup via the Longhorn API
scripts/import-opensuse-aarch64.sh — import the openSUSE Leap aarch64 image as a custom image (LEAP_VERSION default Renovate-bumped with opensuse_leap_version)
Justfile         — Common operation recipes: just apply, just kubeconfig, just ssh worker, just teardown-keep-data, just fmt, just validate
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
- Ubuntu LTS is the default OS (`var.os_family = "ubuntu"`, release in `var.ubuntu_version`, default 26.04); 24.04 is no longer supported. openSUSE Leap is supported via `var.os_family = "opensuse"` — its bootstrap is in `files/lib/bootstrap-opensuse.sh`. Do not add Oracle Linux support. Do not hardcode OS release numbers in code or prose: use `ubuntu_version` / `opensuse_leap_version` (Renovate bumps them).
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
   - `k3s-argocd.sh` — if it involves ArgoCD apps or app Ingresses
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

NetworkPolicies in `gitops/network-policies/`: egress to TCP 443 goes to `0.0.0.0/0` except the
RFC1918 ranges and `169.254.0.0/16` (instance metadata hands out the node's instance-principal
identity); TCP 6443 goes to the RFC1918 ranges only. kube-router matches the endpoint after
kube-proxy's DNAT, so the kube-API is a node's private `:6443`, never `10.43.0.1:443`. In `argocd`,
the policies that keep DNS, HTTPS/kube-API and same-namespace traffic open are sync wave `-1`: Argo CD
applies its own namespace's policies, and the first egress policy isolates every argocd pod.

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
| terraform-docs | fails on diff in fork PRs; auto-committed on same-repo PR branches (except Renovate's) and on push to `main` |

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
  scripts/k3s-ca-export.sh \
  scripts/pre-teardown-backup.sh \
  scripts/longhorn-restore.sh \
  gitops/update-repo-url.sh \
  example/get-kubeconfig.sh \
  example/ssh-node.sh
yamllint -d '{extends: relaxed, rules: {line-length: {max: 200}}}' gitops/ .github/workflows/
actionlint
trivy config . --severity HIGH,CRITICAL --skip-dirs .terraform,example/.terraform
terraform-docs .
```

## Versioning

Plain SemVer: `vX.Y.Z` tags, each a GitHub release that consumers pin as
`source = "github.com/mbologna/k3s-oci?ref=vX.Y.Z"` (nothing builds on a tag), per the
[versioning standard](https://github.com/mbologna/.github/blob/main/VERSIONING.md).

- Never create, move or delete tags, and never edit a version number to cut a release:
  auto-release tags from the commit types (`feat` minor; `fix`, `perf`, `revert` patch; `!` or a
  `BREAKING CHANGE:` footer major).
- Write Conventional Commit subjects; they decide the next version.
- Breaking, for a module consumer, means a removed or renamed variable, or a change that forces
  resources of an existing deployment to be replaced: commit it with `!` and a `BREAKING CHANGE:`
  footer that says how to migrate. Deprecate a variable rather than remove it, and drop it at the
  next major (as with `gateway_api_version`).
- `feat(os):` OS release bumps (`ubuntu_version`, `opensuse_leap_version`) are minor: they reach
  nodes only at the next full rebuild.
- Tags carry no k3s version: k3s follows its channel (`stable` by default, `k3s_version` and the
  system-upgrade Plans), so a new k3s release is not a release of this module.

## Releases and branch protection

- `main` is always releasable and protected by the `main` ruleset, with no bypass, admins
  included: changes arrive only through a pull request, merged with a merge commit, once the `terraform / …`
  checks and `commits / Conventional commits` pass; no force-push, no deletion. Every commit
  lands on `main` as it is and auto-release reads the subjects, so each commit is linted with
  the shared commitlint base. No workflow commits to `main` (the terraform-docs README auto-commit is off).
- Renovate PRs merge only after CI: the shared preset turns on GitHub auto-merge
  (`platformAutomerge`), so GitHub merges an automerge PR once the ruleset's required checks
  (`terraform / …`, `commits / …`) pass, and it sets `internalChecksAsSuccess: false`, so
  Renovate's own stability-days check never counts as CI. A new CI job that must gate merges has to
  be added to the ruleset's required checks too.
- Releases are cut by [auto-release](https://github.com/mbologna/auto-release)
  (`.github/workflows/release.yml`, `strategy: conventional`) every Monday at 06:00 UTC, like every
  other repository: if a `feat:`, `fix:`, `perf:`, `revert:` or breaking commit landed on `main`
  since the last tag, it tags the next version and publishes the GitHub release; chores (Renovate's
  `chore(deps)` updates among them) ship with the next such release. A push that brings a Renovate
  `fix(security):` update releases at once. The bump rules are under Versioning. Write commit
  subjects as changelog entries.
- There is no release PR and nothing is committed back to `main`. Running the Release workflow by
  hand on `main` (*Actions → Release → Run workflow*) releases at once; with `dry_run` on it only
  shows the next version and its notes in the job summary.
- Traefik is the upstream chart in `gitops/apps/traefik.yaml`, tracked by the gitops customManager
  like the other charts. `gateway_api_version` is deprecated and ignored since v2.0.0 (no Gateway
  API CRDs are installed); keep the variable until the next major so old tfvars validate.
- k3s: the module follows the `stable` channel; forks that pin it (Plans `version:` plus a
  committed `*.auto.tfvars` `k3s_version`, each with the renovate comment on the line above) get
  one `k3s` PR per update: patches automerge, a minor only from its x.y.3 release and then
  automerges after the 14-day gate (`matchNewValue` disables x.y.0-x.y.2), majors wait for a
  person. Keep the `k3s-io/k3s` versioning rule (`+k3sN` builds) and `separateMultipleMinor`.
- OS releases: `ubuntu_version` and `opensuse_leap_version` (`vars.tf`) plus `LEAP_VERSION` in
  `scripts/import-opensuse-aarch64.sh` use `datasource=endoflife-date depName=ubuntu` and
  `datasource=custom.opensuse-leap depName=opensuse-leap` (openSUSE's distributions API, Stable/EOL
  releases only; endoflife.date lagged on Leap 16.1). The PRs are `feat(os):` and automerge. Ubuntu: endoflife.date reports a cycle's
  latest point release (`26.04.1`); `extractVersion` keeps only even-year `.04` cycles that have
  one and normalises them to `xx.04` (OCI's `operating_system_version`), so a new LTS arrives from
  its `.1` (90-day `minimumReleaseAge` as backstop); the required Plan check's image postcondition
  fails the PR if OCI has no image yet. openSUSE: `allowedVersions` drops the legacy `42.x`
  numbering; the API has no release dates, so `timestamp-optional` (else the preset's 14-day
  minor gate holds the PR forever); grouped so vars.tf and the script move together. With `os_image_id` null the module
  resolves the image (`data.oci_core_images.opensuse`, OS `openSUSE Leap`, which the import script
  records; in `opensuse_image_compartment_ocid`, default tenancy root): newest of
  `opensuse_leap_version`, else newest of any release, and the `opensuse_image_matches_leap_version`
  check warns until the new release is imported. A bump reaches nodes only on a full rebuild:
  the instance configurations ignore `instance_details` and the pools ignore
  `instance_configuration_id` (`compute.tf`), so running nodes and pool replacements keep their
  image, and the bump PR's plan is empty. The same holds for newer image builds of the same release.
- `.github/workflows/plan.yml` (`Plan / tofu plan (example)`) runs a read-only `tofu plan` of
  `example/` against a live deployment on same-repository PRs: a dedicated OCI user in a
  read-only group, state read from the remote backend with `-lock=false`, and only changed
  resource addresses in the log (the repo's logs are public; never print the plan itself).
  Without its secrets it reports a notice and succeeds. Setup and secret names: README, "CI
  plan against a live deployment". It is a required check since 2026-11-16, so provider updates
  automerge on an empty plan (no providers rule in renovate.json any more). PLAN_TFVARS needs `public_key = "..."` when the tfvars use `public_key_path`.
- Release notes come from commit subjects: add context in the commit body, or edit the release
  on GitHub after it is published. The Releases page is the whole history; there is no
  `CHANGELOG.md`.

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
- Do not add Oracle Linux support — Ubuntu LTS (default) and openSUSE Leap (via `var.os_family`) are the two supported OS families
- Do not remove `lifecycle { prevent_destroy = true }` from the Vault or its key
- Do not hardcode secrets, OCIDs, or credentials anywhere
- Do not remove the `# renovate:` comments on version variables
- Do not commit `example/terraform.tfvars` (it is gitignored; `.tfvars.example` is the template)
- Do not break the `terraform validate` step — `server-vars.sh.tpl` / `agent-vars.sh.tpl` vars must match what `data.tf` passes
- **Do not suggest terminating TLS at the OCI load balancer** — the public-facing LB is the OCI NLB (`nlb.tf`), which operates at L4 TCP only (`protocol = "TCP"`) and cannot inspect or terminate TLS. The one free OCI Flexible LB allocation (L7, TLS-capable) is consumed by the internal kubeapi LB (`lb.tf`). TLS must be terminated at Traefik. cert-manager + Let's Encrypt handles certificate issuance and renewal automatically.
- **Do not add nginx or other ingress controllers** — Traefik is the ingress implementation (since v2.0.0). HTTP/HTTPS routing uses standard Kubernetes `Ingress` resources with Traefik `Middleware`s; `IngressRoute` is fine where an Ingress can't express it (the module itself needs none).
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
- **Do not add an nginx stream proxy** back. The OCI NLB routes directly to Traefik's NodePorts
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

### Traefik (ingress)

- Upstream chart via ArgoCD (`gitops/apps/traefik.yaml`, sync wave 1, namespace `traefik`); k3s's bundled Traefik stays disabled (`--disable traefik` in `k3s-server.sh`) so the version is pinned and Renovate-managed. ServiceLB is disabled too (`--disable servicelb`): a `type: LoadBalancer` Service without a `loadBalancerClass` (e.g. `tailscale`) stays Pending; reach in-cluster services through Traefik's NodePorts.
- **DaemonSet** (one pod per node): every NLB backend serves ingress locally, no cross-node hop, no single-pod SPOF. Updates surge (maxUnavailable 0, maxSurge 1), so a node keeps serving while its new pod starts.
- `priorityClassName: system-cluster-critical`, like kured and Longhorn's instance managers.
- No PDB: Kubernetes PDBs don't apply to DaemonSet pods; kured drains with `--ignore-daemonsets`.
- **NodePort 30080/30443** must match `ingress_controller_http_nodeport` / `ingress_controller_https_nodeport` (the NLB backends and NSG rules). **`externalTrafficPolicy: Local`** keeps the client IP (the NLB preserves it); Cluster would SNAT and break rate limits and allowlists.
- **websecure is the default entrypoint** (`asDefault`), with TLS: Ingresses without an explicit entrypoint are served on :443 only. **:80 redirects** to HTTPS at router priority 1, so cert-manager's HTTP-01 solver Ingress, pinned to `web` through the ClusterIssuers' `ingressTemplate` annotation (`traefik.ingress.kubernetes.io/router.entrypoints: web`), outranks it. Do not raise the redirect's priority or remove the solver annotation: HTTP-01 would stop working. Plain-HTTP Ingresses pin themselves to `web`.
- **TLSOption `default`** (chart values): TLS 1.2+, AES-GCM suites. Go's TLS has no aarch64 cipher problem (Envoy/BoringSSL had one with ChaCha20).
- **No Ingress status**: the NodePort Service has no load-balancer address and `gitops/` is IP-free, so `publishedService` is off and status stays empty. `gitops/apps/argocd.yaml` adds an Argo CD health customization that treats an Ingress as Healthy; cloud-init's Ingresses get `external-dns.alpha.kubernetes.io/target: <public NLB IP>` (`PUBLIC_NLB_IP`).
- Middlewares: `gitops/argocd/rate-limit.yaml` (Argo CD UI, 100 req/s per client IP) and the Longhorn basicAuth Middleware cloud-init creates (Secret key `users`, `{SHA}` hash from `k3s-secrets.sh`). Reference them as `<namespace>-<name>@kubernetescrd`. Middleware manifests in apps that sync before wave 1 carry `SkipDryRunOnMissingResource=true`.
- Certificates live in the Ingress's namespace (an Ingress can only use a TLS Secret of its own); the HTTP-01 solver pods run there too, so those namespaces allow ingress from `traefik` to `acme.cert-manager.io/http01-solver` pods on 8089 (`gitops/network-policies/argocd.yaml`, `longhorn-system.yaml`).
- Network policies: `gitops/network-policies/traefik.yaml` (default-deny; ingress on the container ports 8000/8443, which kube-router matches post-DNAT, never the nodePorts; egress to backends, 6443, DNS). The `traefik` namespace is created in `namespaces.yaml` (wave -1) so the policies apply before the app.

### Longhorn storage
- Replica count is **explicitly pinned to 2** in `gitops/apps/longhorn.yaml` via `defaultSettings.defaultReplicaCount=2` and `persistence.defaultClassReplicaCount=2`. Do not rely on the upstream chart default. With 2 nodes and hard replica anti-affinity, a third replica can never be scheduled — **do not increase it**.
- Longhorn is managed entirely by ArgoCD (`gitops/apps/longhorn.yaml`). Cloud-init does NOT install Longhorn.
- **One replica per controller** (CSI attacher/provisioner/resizer/snapshotter, global manager, UI; chart defaults 3/3/2) and `guaranteedInstanceManagerCPU` 5%: on two 1-OCPU nodes the extra replicas were 9 pods mostly on the control plane, whose memory k3s needs. Volume I/O is served by the instance managers; a rescheduling controller only delays provisioning, attach, resize and snapshots for seconds. Don't raise them back without a reason.
- With 2 nodes and 2 replicas, either node can be lost without PVC data loss (one replica per node). There is no 3-replica StorageClass — it would be unschedulable. Off-cluster protection comes from Longhorn backups (`enable_longhorn_backup`).
- etcd is single-node: losing the server's boot volume means restoring from an etcd snapshot, regardless of Longhorn replicas.

### Longhorn UI BasicAuth
- Password is generated by `random_password.longhorn_ui_password` in `data.tf` and exported by
  `files/server-vars.sh.tpl` as `LONGHORN_UI_PASSWORD_PLAIN` (or fetched from Vault when `enable_vault = true`).
- `files/lib/k3s-secrets.sh` generates a `{SHA}` hash with openssl and creates
  `Secret/longhorn-basic-auth-secret` (key `users`) in `longhorn-system` at bootstrap time. The hash requires
  runtime password resolution so it cannot be a static gitops file.
- `gitops/longhorn/ingress.yaml` is a template — users configure the `Ingress`, basicAuth `Middleware`
  and `Certificate` resources there pointing to the pre-created Secret (key `users`).
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
  - `k3s-bootstrap.sh` — `run_bootstrap()` (calls the above)
- **GitOps-first**: cloud-init only bootstraps what ArgoCD cannot self-manage:
  - cert-manager Helm + ClusterIssuers (email is a runtime Terraform var, not static git)
  - ArgoCD Helm + App of Apps bootstrap
  - External Secrets Operator Helm + ClusterSecretStore (conditional, vault_ocid is runtime)
  - Pre-create Kubernetes Secrets with runtime values (passwords, endpoints)
  - Hostname-specific Ingress + TLS Certificate (+ Middleware) (NLB IP is runtime; see `configure_argocd_ingress()` in `k3s-argocd.sh` and the "Hostname-specific HTTPS resources" section in Deploying web apps)
- **Managed by ArgoCD, NOT cloud-init**: Traefik, Longhorn, kured,
  system-upgrade-controller — all in `gitops/apps/*.yaml`. The opt-in components live in
  `gitops/optional/` and get an Application only when their flag is on: ESO through the
  `optional-external-secrets` wrapper (path `gitops_optional_path`; `""` skips the wrapper), external-dns
  through `create_external_dns_app()`.
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
- CI (`terraform-docs` job) auto-commits README drift on same-repo PR branches (except Renovate's)
  and on push to `main` (this is how Renovate version bumps reach the README defaults table).
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
- With `enable_vault = true` the IAM policy grants `read secret-bundles` only on the secrets cloud-init fetches (`local.boot_vault_secret_ids` in `iam.tf`: the module's boot secrets plus `k3s_ca_vault_secret_id`, matched by `target.secret.id`). A new secret that cloud-init fetches **must be added to that list**, or nodes get `NotAuthorizedOrNotFound` at boot. The broad `read secret-family` is granted only when `enable_external_secrets && external_secrets_instance_principal`.
- `k3s_ca_vault_secret_id` points at a **user-created** secret (not module-managed, not counted
  above): a base64 tar.gz of `server-ca.{crt,key}` + `client-ca.{crt,key}`. `seed_custom_ca()` in
  `k3s-server.sh` extracts it into `/var/lib/rancher/k3s/server/tls` before `--cluster-init` (k3s
  reuses existing CA files), and `verify_custom_ca()` logs whether k3s kept it. It fails closed: do not
  add a fallback that lets k3s mint a new CA, since that silently invalidates every stored kubeconfig.
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
- **Longhorn backup bucket** (`enable_longhorn_backup = true`): versioned, `NoPublicAccess`, name `${cluster_name}-longhorn-backup`. With `create_longhorn_backup_user = true` (resources in `iam.tf`: user, capabilities, group, membership, policy — all `${cluster_name}-longhorn-backup`) cloud-init wires everything: `longhorn-backup-secret` with `AWS_ENDPOINTS`, the `backuptargets.longhorn.io/default` CR, and the `daily-backup` RecurringJob (`longhorn_backup_schedule`, `longhorn_backup_retain`) via SSA (no snapshot-cleanup job: it fails on detached volumes, and Longhorn cleans up its own snapshots) (`setup_longhorn_backup_target()` in `k3s-secrets.sh`). Otherwise the `longhorn_backup_setup` output prints the three manual steps (Customer Secret Key → `longhorn-backup-secret` with `AWS_ENDPOINTS` → patch the `backuptargets.longhorn.io/default` CR). Longhorn ≥ 1.8 has no `backup-target` Setting — always use the BackupTarget CR. Nodes need no IAM grant on this bucket (Longhorn authenticates with the Customer Secret Key).
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
- Syncs Ingress hosts to Cloudflare DNS. Traefik publishes no Ingress status behind the NLB, so
  each Ingress needs `external-dns.alpha.kubernetes.io/target: <public NLB IP>` (cloud-init adds it
  to the ArgoCD and Longhorn Ingresses); `.../hostname` adds names beyond the Ingress's hosts.
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
- The store authenticates as the nodes, so with `external_secrets_instance_principal = true` (default) the policy grants `read secret-family` on the whole compartment. Callers that replace the store with a user-principal (API key) one set it to `false`, and nodes fall back to reading only their boot secrets.
- See `gitops/external-secrets/` for the ClusterSecretStore template and example ExternalSecret CRs.
- Users create `ExternalSecret` resources referencing Vault secret OCIDs; the operator syncs them
  into Kubernetes Secrets automatically and rotates on the configured refresh interval.

### Adding HTTPS ingress for a new app

Use `configure_app_ingress()` in `files/lib/k3s-argocd.sh` when a new cluster component needs
an HTTPS endpoint with a cert-manager TLS certificate. It waits for the `traefik` IngressClass,
then creates a Certificate and an Ingress (SSA, field-manager `cloud-init-bootstrap`) in the
Service's namespace, with optional Middlewares and the external-dns target annotation.

**Signature:**
```bash
configure_app_ingress <hostname> <namespace> <service> <port> <name> [middlewares]
```

`name` is the Ingress name (the Certificate and Secret are `<name>-tls`); `middlewares` is a
comma-separated list of `<namespace>-<middleware>@kubernetescrd` references.

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
       "myapp"
   }
   ```
6. Call it from `run_bootstrap()` in `k3s-bootstrap.sh`. Ingress setup is non-fatal (the
   cluster works without it), so follow the existing pattern and only warn:
   ```bash
   configure_myapp_ingress || echo "WARNING: configure_myapp_ingress failed — cluster is functional; ingress can be retried via cloud-init."
   ```
7. If the namespace has a default-deny ingress policy, allow `traefik` to the app's pods and to
   the HTTP-01 solver pods (see `gitops/network-policies/argocd.yaml`).

**Note:** For apps that also need BasicAuth (like Longhorn), create the `Middleware` first and
pass it to `configure_app_ingress()`. See `configure_longhorn_ingress()` as the reference.

### Deploying web apps — known pitfalls

The following issues were discovered while deploying the first HTTPS application. Document them here so agents do not repeat the investigation.

**NLB `is_preserve_source = true` and NSG rules**

The public NLB uses `is_preserve_source = true` on all backend sets. This means packets arrive at node VNICs with the **real client IP** as source, not the NLB's own IP. NSG rules that use `source_type = NETWORK_SECURITY_GROUP` pointing at the NLB NSG will only match health-check traffic (which originates from the NLB's VNIC) — real user traffic is silently dropped. NodePort rules for HTTP (:30080) and HTTPS (:30443) on both the workers NSG and the servers NSG (servers are also NLB backends) must use `source = "0.0.0.0/0"` with `source_type = "CIDR_BLOCK"`. Nodes are in a private subnet with no public IPs, so this is safe.

**cert-manager HTTP-01 self-check blocked by NetworkPolicy**

`gitops/network-policies/cert-manager.yaml` deploys egress NetworkPolicies that kube-router enforces strictly. The original `allow-https-egress` policy only permitted TCP 443/6443/8443 — it did NOT allow TCP 80. cert-manager's HTTP-01 solver performs a self-check GET request to `http://<hostname>/.well-known/acme-challenge/...` before submitting to Let's Encrypt. With port 80 egress blocked, kube-router REJECTs the packet with ICMP port-unreachable, which Go's `net/http` reports as "connection refused". The `allow-http-egress` NetworkPolicy was added to fix this — do not remove it.

**The HTTP->HTTPS redirect must stay below the HTTP-01 solver**

Traefik's entrypoint redirect is a router on `web`; by default its priority is the highest, which
would swallow cert-manager's ACME challenge. `gitops/apps/traefik.yaml` sets it to 1, websecure is
the default entrypoint (so no ordinary Ingress listens on `web`), and the ClusterIssuers pin the
solver Ingress to `web`. Keep all three; DNS-01 (`enable_dns01_challenge = true`) avoids the
question entirely.

**Hostname-specific HTTPS resources are managed by cloud-init, not gitops/**

NLB IP changes on every redeploy. Hardcoding sslip.io addresses in `gitops/` breaks GitOps: every redeploy requires manual file edits. The design:
- `local.argocd_hostname` auto-computes `argocd.<nlb-ip>.sslip.io` (or uses `var.argocd_hostname` if set).
- `local.longhorn_hostname` uses `var.longhorn_hostname` (no sslip.io fallback — Longhorn UI is opt-in).
- `files/server-vars.sh.tpl` exports `ARGOCD_HOSTNAME`, `LONGHORN_HOSTNAME`.
- `files/lib/k3s-argocd.sh:configure_app_ingress(hostname namespace service port name [middlewares])` is the generic helper.
  - Creates the cert-manager Certificate in the app namespace
  - Creates the app Ingress in the app namespace (SSA, field-manager=cloud-init-bootstrap), with the external-dns target annotation
- `configure_argocd_ingress()`, `configure_longhorn_ingress()` each call the generic helper.
- `configure_longhorn_ingress()` first applies the basicAuth `Middleware`.

**Do NOT use CSA (kubectl apply without --server-side) to patch ArgoCD-managed resources.** CSA sets the `kubectl.kubernetes.io/last-applied-configuration` annotation, which confuses ArgoCD's 3-way merge on the next sync. Always use SSA with a custom field-manager for cloud-init patches to ArgoCD-managed resources.

### Feature flag co-dependencies (`checks.tf`)
Terraform 1.9+ `check {}` blocks in `checks.tf` catch invalid feature flag combinations at plan time
before any OCI API call is made:
- `enable_external_secrets = true` requires `enable_vault = true` and `region != null`
- `enable_dns01_challenge = true` requires `cloudflare_api_token != null`
- `enable_external_dns = true` requires `cloudflare_api_token`, `cloudflare_zone_id`, and `external_dns_domain_filter`
- `enable_tailscale = true` requires `enable_vault = true` and both `tailscale_oauth_client_id` and `tailscale_oauth_client_secret` set
- `k3s_ca_vault_secret_id` requires `enable_vault = true`
- `create_longhorn_backup_user = true` requires `enable_longhorn_backup = true`, and is mutually exclusive with `user_ocid`
- automatic Longhorn backup wiring (`create_longhorn_backup_user` or `user_ocid`) requires `region != null`
- `os_family = "opensuse"`: the resolved or pinned image should be the `opensuse_leap_version` release (warns after a Renovate bump until the new release is imported)

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
- `ubuntu_version`: `^[0-9]{2}\.04$` (LTS only); `opensuse_leap_version`: `^[0-9]+\.[0-9]+$`
- `opensuse_image_compartment_ocid`: tenancy or compartment OCID, or null

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
- Cloud-init installs `/usr/local/bin/etcd-snapshot-upload.sh` + cron job on every server, at the hours in `etcd_snapshot_upload_hours` (default `*/6`, UTC), minute :00–:04 per node.
- k3s's built-in snapshot schedule is moved to `15 */12 * * *` (`--etcd-snapshot-schedule-cron`) — the default `0 */12 * * *` collides with the upload cron and fails with "snapshot save already in progress". Do not align the two schedules.
- Snapshots are uploaded to `${cluster_name}-terraform-state` bucket under `etcd-snapshots/${CLUSTER_NAME}/<hostname>/` using OCI CLI instance_principal auth — **no Customer Secret Keys required**.
- Pruning keeps the newest `etcd_snapshot_retention` objects across the whole `etcd-snapshots/${CLUSTER_NAME}/` prefix (not per hostname), so prefixes of replaced servers are cleaned up too. There is deliberately no age-based expiry rule: it would delete the last restore points of a cluster that has been down for a while.
- When a single server bootstraps a fresh cluster (`--cluster-init`) and snapshots already exist in the bucket, `_warn_if_previous_snapshots_exist()` logs a loud WARNING with the `k3s server --cluster-reset --cluster-reset-restore-path` restore steps — a replaced server otherwise silently starts an empty cluster.
- IAM policy `manage objects in bucket ${cluster_name}-terraform-state` (added in `iam.tf`) enables this.
- Retention is configurable via `etcd_snapshot_retention` (default: 5 snapshots).
- Servers start with `--secrets-encryption` (`k3s_secrets_encryption`, default `true`), so the snapshots hold Secrets AES-CBC encrypted. The key lives in the k3s bootstrap data, which is encrypted with the cluster token, so a restore needs the same token and a server started with the flag. The flag applies at install time only; a running cluster is switched over with `k3s secrets-encrypt enable`, a restart with the flag, `rotate-keys` and a second restart.
- These snapshots are the primary recovery path for split-brain and etcd quorum loss. The server logs the restore steps when it finds old snapshots (see README "After a rebuild that kept the buckets").

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

### Server memory (placement)
- The control plane is short of memory, not CPU: k3s server holds ~2.2 GiB (peak 2.4-2.9) because
  every pod's containerd-shim is charged to its unit (`system-reserved` 3 GiB there). The small
  controllers (Argo CD's parts except argocd-server, cert-manager, External Secrets, the Tailscale
  operator) therefore *prefer* the worker; the nightly descheduler returns them after a drain.
  Measured numbers: README "Memory budget (measured)". Don't move a controller back to the
  control plane without re-measuring.

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
- To restrict access: add a Traefik `Middleware` (`ipAllowList` or `forwardAuth`) to the ArgoCD
  Ingress's `router.middlewares` annotation, or set `var.my_public_ip_cidr` and add an NSG rule that
  limits NLB HTTP/HTTPS to your IP. Set `var.argocd_hostname = ""` to skip the ArgoCD ingress (`null` derives the sslip.io hostname) and reach the UI another way, e.g. a Tailscale LoadBalancer Service.
