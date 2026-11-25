# Updates, releases and CI

How nodes, k3s and the stack stay up to date, how module releases are versioned, and the CI plan check against a live deployment.

## Automatic updates and reboots

`unattended-upgrades` applies Ubuntu security patches daily and sets `/var/run/reboot-required` when a kernel update needs a reboot.

[kured](https://github.com/kubereboot/kured) checks every node's reboot flags (below) and, when one says a reboot is due:
1. Acquires a cluster-wide lock (only one node reboots at a time)
2. Cordons + drains the node
3. Reboots
4. Waits for the node to return and uncordons it

kured reboots between 02:15 and 04:15 UTC, after the package timers have finished
(`gitops/apps/kured.yaml`), and checks every minute, so the second node follows as soon as the first is
back. A reboot that installs a security fix happens that same night, any day of the week; any other
reboot waits for Tuesday, Wednesday or Thursday. The nodes tell them apart: `security-reboot-check`
(Ubuntu: after each package run and hourly) writes `/run/security-reboot-required` when a package in
`/run/reboot-required.pkgs` came from a `-security` pocket, and on openSUSE the security-only patch run
writes it when its patches need a reboot. kured's sentinel command reboots for that file on any night
and for `/var/run/reboot-required` only Tuesday to Thursday. Every schedule the module creates is in
UTC, so that order cannot change at a daylight-saving switch.

Two guards keep this from stalling on Ubuntu: `apt-daily.service` (the package-list refresh) is killed
after an hour, because a fetch hung for weeks once and quietly stopped all patching; and
`unattended-upgrades.service` restarts with `systemd-logind`, so its shutdown delay lock never outlives
a logind restart and holds up a reboot.

k3s itself is upgraded by system-upgrade-controller, one node at a time, in a nightly window
(23:00-23:59 UTC, `gitops/system-upgrade/plans.yaml`) that ends before every other nightly job. An
upgrade cordons the node and restarts k3s without draining it: running containers stay up across a k3s
restart, and draining only shuffled every pod onto the other node. kured's lock does not cover these
upgrades, so kured is configured to wait while an upgrade Job is running
(`blockingPodSelector: [upgrade.cattle.io/plan]`). kured's lock expires after 2 hours (`lockTtl`), so
a node that dies mid-reboot cannot block every later reboot, and a drain stuck on a
PodDisruptionBudget gives up after 15 minutes and is retried at the next check.

This keeps the cluster patched with no manual intervention, one node at a time. It is not zero-downtime: a reboot's drain restarts every single-replica pod on that node somewhere else, and while the control-plane node reboots the Kubernetes API is down. Run two replicas spread across the nodes ([Resilience](applications.md#resilience-spread-replicas-across-nodes)) for anything that must stay up through the nightly window.

## Dependency updates (Renovate)

[Renovate](https://docs.renovatebot.com) tracks Terraform providers, k3s, all stack component versions (via `# renovate:` inline comments in `vars.tf` and `gitops/apps/*.yaml`), and GitHub Actions. Enable it on your fork with the [Renovate GitHub App](https://github.com/apps/renovate); `renovate.json` extends a shared preset you may want to replace with your own.

**k3s** follows the `stable` channel by default, so there is nothing to bump. To pin it instead, put a `version` with a renovate comment directly above it in both Plans (`gitops/system-upgrade/plans.yaml` shows how) and the same release in a committed `example/k3s-version.auto.tfvars` (`git add -f`: `.gitignore` excludes `*.tfvars`, since `terraform.tfvars` holds secrets):

```hcl
# renovate: datasource=github-releases depName=k3s-io/k3s
k3s_version = "v1.36.6+k3s1"
```

Renovate then updates both in one `k3s` PR:

| Update | What happens |
|---|---|
| Patch (`v1.36.6` → `v1.36.7`) | Automerges after the preset's 7-day gate, in its own PR, so a waiting minor never absorbs a patch for the running minor |
| Minor, new version `x.y.0`–`x.y.2` | No PR: a new minor is taken only from its third patch, once the first regressions are fixed |
| Minor, new version `x.y.3` or later | Automerges after the 14-day gate; system-upgrade-controller applies it in the next upgrade window |
| Major | Waits for a person (`manual-review`) |

**OS releases** come from [endoflife.date](https://endoflife.date) (Ubuntu), [openSUSE's release API](https://get.opensuse.org/api/v0/distributions.json) (Leap) and Fedora CoreOS's [stable stream](https://builds.coreos.fedoraproject.org/streams/stable.json) and update graph, and arrive as PRs that automerge after CI; the OS release bumps are `feat(os):`, so each one ships in a release:

| Release | Bump | After it merges |
|---|---|---|
| Ubuntu (`ubuntu_version`) | Next LTS (`xx.04` of an even year, never interim releases), once its `.1` point release is out, when Ubuntu itself opens LTS-to-LTS upgrades (and at least 90 days after release). The required Plan check fails the PR if OCI has no aarch64 image for it yet | The next full rebuild (`tofu destroy` + `apply`, or `just teardown-keep-data`) boots the new release. Until then nothing changes: the instance configurations ignore image changes, so running nodes and pool replacements keep the image the pool was created with |
| openSUSE Leap (`opensuse_leap_version` and the import script's default, one PR) | Next Leap release, as soon as openSUSE marks it Stable (the legacy `42.x` numbering is ignored) | Run `scripts/import-opensuse-aarch64.sh` (with `--variant immutable` for Leap Immutable); the next full rebuild then boots the new release without `os_image_id`. Until it is imported, plans warn and a rebuild boots the newest imported image |
| Fedora CoreOS major (`fcos_version`, the boot image) | The stable stream's new major | Run `scripts/import-fcos-aarch64.sh`. Until then plans warn and new nodes boot the newest imported image; either way they pivot to `fcos_os_version` before k3s starts |
| Fedora CoreOS release (`fcos_os_version` and the `fcos-os` Plan's `version`, one PR) | Every new stable release (about every two weeks), once FCOS's phased rollout of it has finished ([update graph](https://updates.coreos.fedoraproject.org/v1/graph?basearch=aarch64&stream=stable&rollout_wariness=1&oci=true) at `rollout_wariness=1`) | The `fcos-os` Plan updates the FCOS nodes in its next window (Tue-Thu 02:15-04:15 UTC), one drained node at a time along the update graph; new nodes pivot to it on first boot |

## Versioning

Releases follow SemVer: [auto-release](https://github.com/mbologna/auto-release) tags `vX.Y.Z` from the Conventional Commit types (`feat` minor; `fix`, `perf`, `revert` patch; a breaking change major) and publishes a GitHub release; you consume one as `?ref=vX.Y.Z`. A major is what may need changes on your side: a removed or renamed variable, or a change that forces resources of an existing deployment to be replaced. An OS release bump (`feat(os)`, above) is a minor, since it reaches nodes only at the next full rebuild. k3s follows its channel (`stable` by default), so tags carry no k3s version. See the [versioning standard](https://github.com/mbologna/.github/blob/main/VERSIONING.md).

## CI plan against a live deployment

`.github/workflows/plan.yml` runs `tofu plan` of `example/` against a live deployment on every same-repository pull request, read-only: an empty plan shows that a provider or chart bump changes nothing in the tenancy. It needs the deployment's state in a remote backend ([Remote Terraform state](data.md#remote-terraform-state-oci-object-storage)) and its own OCI user that may only read. Only the addresses of changed resources reach the log, since the full plan holds OCIDs, IP addresses and tfvars values. Until the secrets below exist, the job reports a notice and succeeds, so fork pull requests (which get no secrets) are not blocked.

To set it up:

1. **Group and policy** (Identity → Domains → Default → Groups, then Policies, in the root compartment):

   ```text
   Group:  k3s-oci-plan
   Policy: tofu-plan-readers
     Allow group k3s-oci-plan to read all-resources in tenancy where all {request.permission != 'SECRET_BUNDLE_READ', request.permission != 'OBJECT_READ'}
     Allow group k3s-oci-plan to read objects in tenancy where target.bucket.name = '<state bucket>'
   ```

   The first statement lets the plan refresh every resource without reading secret contents or the etcd snapshots and Longhorn backups in the module's buckets; the second reads the state object only. The state holds every cluster secret, so treat these credentials like the state itself.
2. **User** `k3s-oci-plan` (no console password), member of `k3s-oci-plan`, with an API key (Users → API keys → Add) and a customer secret key (Users → Customer secret keys) for the S3-compatible state backend.
3. **GitHub secrets** (Settings → Secrets and variables → Actions):

   | Secret | Value |
   |---|---|
   | `OCI_PLAN_USER_OCID`, `OCI_PLAN_FINGERPRINT`, `OCI_PLAN_TENANCY_OCID`, `OCI_PLAN_REGION` | the API key's config snippet |
   | `OCI_PLAN_PRIVATE_KEY` | the API key's private key (PEM) |
   | `PLAN_STATE_ACCESS_KEY_ID`, `PLAN_STATE_SECRET_ACCESS_KEY` | the customer secret key |
   | `PLAN_BACKEND_OVERRIDE` | your `example/backend_override.tf`; the job overrides its `profile` with its own |
   | `PLAN_TFVARS` | your `example/terraform.tfvars` followed by any `*.auto.tfvars`, the inputs the deployment was applied with; set it again after changing them (`cat terraform.tfvars *.auto.tfvars \| gh secret set PLAN_TFVARS`). If your tfvars point at the SSH key with `public_key_path` (the default, `~/.ssh/id_ed25519.pub`), append `public_key = "<that key>"`: the runner has no such file, and the key must be the one the deployment was built with, or the plan shows the instances changing |

4. Add `Plan / tofu plan (example)` to the `main` ruleset's required checks, so a pull request whose plan changes resources can't merge (a plan that only changes root outputs passes).

In this repository the job is a required check, so Terraform provider updates automerge once their plan is empty. On a fork, set it up before relying on that: without its secrets it reports a notice and succeeds, so a provider update would automerge unplanned.
