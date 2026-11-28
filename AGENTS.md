# AGENTS.md — guidance for AI coding agents

Terraform/OpenTofu module for a k3s cluster on OCI's free allowance, on an image-based OS.
Sibling of `mbologna/talos-oci`. Start with [README.md](README.md) and
[docs/design.md](docs/design.md).

## Hard constraints

- **Free allowance only.** A1.Flex up to `a1_free_ocpus` / `a1_free_memory_gbs` (4 / 24 on Pay
  As You Go, 2 / 12 otherwise), 200 GB block storage, 5 volume backups, one NLB, one 10 Mbps
  flexible LB, one MySQL.Free system, Object Storage within the free tiers. Flag anything paid
  instead of adding it.
- **Nothing administrative is public.** The Kubernetes API sits behind the internal load
  balancer and Bastion; the public NLB carries only 80/443 to Traefik's NodePorts.
- **Terraform never connects to the nodes.** It renders each node's script; the nodes install
  k3s and the first one Argo CD on their own.
- **Custom images are transient**: import, launch, delete. The instances ignore `source_details`
  and `metadata`.
- **Image-based OSes only**: opensuse (Leap Immutable, the default), fcos, flatcar. Don't add a
  mutable distribution back.
- Secrets never go into git; the state holds the token, the CA keys and the database password.

## File map

```
versions.tf       providers (oci, random, tls, cloudinit)
vars.tf           inputs; versions carry # renovate: comments
locals.tf         node IPs, first node, kine endpoint, k3s token
ca.tf             cluster server/client CAs and the admin kubeconfig
nodes.tf          k3s config, bootstrap manifests, node script, cloud-init / Ignition, script PARs
network.tf        VCN, IGW, NAT, Service Gateway, route tables, security lists, subnets
nsg.tf            NSGs: nodes, internal LB, public NLB, MySQL
lb.tf             internal flexible LB: 6443 to every server
nlb.tf            public NLB: 80/443 to the ingress NodePorts
compute.tf        one oci_core_instance per node (fixed IP, user_data, IMDSv2 only)
mysql.tf          MySQL HeatWave (datastore = "mysql")
objectstorage.tf  backups bucket (versioned, noncurrent versions purged after 2 days)
iam.tf            Object Storage service grant for the bucket's lifecycle rule
backup.tf         weekly boot-volume backups
monitoring.tf     ONS topic, alarms, APM free-tier synthetic monitor (alert_email)
bastion.tf        OCI Bastion for the port forwards
checks.tf         free-allowance and user_data size checks
output.tf         outputs
files/            node script: node-vars.sh.tpl (the only Terraform template) + lib/*.sh
gitops/           default App of Apps and opt-in templates
scripts/          import-image, deploy, tunnel, validate-gitops, check-bootstrap-chart-versions
tests/            offline render tests (tofu test, OCI provider mocked)
example/          root module used by CI and as a starting point
docs/             design.md, operations.md
```

## Node script

- `files/node-vars.sh.tpl` is the only Terraform template; `files/lib/*.sh` are plain bash,
  concatenated by `nodes.tf` (`local.script_files`). The k3s config, the bootstrap manifests and
  the CA files are rendered in Terraform and passed in base64.
- No python, no OCI CLI on the nodes: Flatcar and Fedora CoreOS have neither.
- Every OS runs the script from `k3s-oci-bootstrap.service` until `two-phase-done.sh` marks it
  done; opensuse and fcos reboot once into staged packages (`two_phase_begin`).
- Run `tofu test` after changing `nodes.tf`, `ca.tf` or `files/`; CI runs it.

## Checks before pushing

```bash
tofu fmt -recursive
tofu init -backend=false && tofu validate && tofu test
(cd example && tofu init -backend=false && tofu validate)
tflint --init && tflint --recursive
shellcheck --severity=warning files/lib/*.sh scripts/*.sh gitops/update-repo-url.sh
yamllint -d '{extends: relaxed, rules: {line-length: {max: 200}}}' gitops/ .github/workflows/
scripts/check-bootstrap-chart-versions.sh && scripts/validate-gitops.sh
actionlint
```

## Commits and releases

Conventional Commits (header ≤ 72 characters, imperative, no AI attribution trailers), one
concern per commit, merged through pull requests with merge commits. auto-release tags versions
from the commit types every Monday; never create tags by hand. A breaking change for a module
consumer (a removed or renamed variable, a change that replaces existing resources) is `!` with a
`BREAKING CHANGE:` footer.
