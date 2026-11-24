# k3s-oci

[![CI](https://github.com/mbologna/k3s-oci/actions/workflows/ci.yml/badge.svg)](https://github.com/mbologna/k3s-oci/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/mbologna/k3s-oci)](https://github.com/mbologna/k3s-oci/releases/latest)

A Terraform/OpenTofu module that builds a [k3s](https://k3s.io) cluster on the [OCI Always Free tier](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm): one control-plane node and one worker on Arm A1.Flex, with ingress, storage, GitOps and backups installed, for $0 a month.

## What you get

- Two A1.Flex nodes (1 OCPU / 6 GB each) in a private subnet, k3s with embedded etcd, and every Always Free resource used once: one public NLB, one internal load balancer, 2 × 100 GB boot volumes.
- Traefik on every node behind the NLB, with real client IPs; cert-manager with Let's Encrypt; Longhorn volumes replicated across both nodes; Argo CD managing the stack from `gitops/` ([Deploying applications](docs/applications.md)).
- Secrets in a free OCI Vault, fetched at boot by the nodes' instance principal instead of sitting in user-data; optional External Secrets to sync them into the cluster.
- etcd snapshots and Longhorn backups in versioned Object Storage buckets, weekly boot-volume backups, and a rebuild that keeps all of them ([State, secrets, backups and rebuilds](docs/data.md)).
- Patches and reboots without intervention: OS updates on a schedule, kured rebooting one drained node at a time, k3s upgrades through system-upgrade-controller, dependency bumps through Renovate ([Updates, releases and CI](docs/updates.md)).
- A choice of node OS: Ubuntu LTS (default), openSUSE Leap (Minimal or Immutable) or Fedora CoreOS ([Operating systems](docs/operating-systems.md)).
- Opt-in extras: MySQL HeatWave, Cloudflare DNS through External DNS, the Tailscale operator, direct SSH or kube-API on the NLB, and a spend alert.

## Architecture

```mermaid
graph TD
    Internet(["🌐 Internet"])

    subgraph public["Public Subnet · 10.0.0.0/24"]
        NLB["🔀 Public NLB (Always Free)
HTTP :80 · HTTPS :443
optional: kubeapi :6443 · SSH :22"]
    end

    subgraph private["Private Subnet · 10.0.1.0/24 · no public IPs"]
        ILB["⚖️ Internal Flex LB (Always Free)
kubeapi VIP :6443"]

        CP["control-plane-0  ·  A1.Flex (1 OCPU / 6 GB)
k3s-server · etcd · Traefik · Longhorn · user workloads"]

        W["worker-0  ·  A1.Flex (1 OCPU / 6 GB)
k3s-agent · Traefik · Longhorn · user workloads"]
    end

    NAT["🌍 NAT Gateway (Always Free)"]
    Bastion["🔐 OCI Bastion Service
optional · Always Free"]

    Internet -->|HTTP / HTTPS| NLB
    NLB -->|"Traefik NodePorts :30080 / :30443"| CP & W
    NLB -. "kubeapi :6443
expose_kubeapi=true" .-> CP
    NLB -. "SSH :22
expose_ssh=true" .-> CP & W
    ILB --> CP
    W -->|joins via kubeapi| ILB
    private -->|outbound| NAT --> Internet
    Bastion -. "SSH tunnel
enable_bastion=true" .-> private
```

Both nodes sit in a private subnet with no public IP. The public NLB forwards HTTP and HTTPS to Traefik's NodePorts on both nodes and preserves client IPs; it can also expose SSH and the Kubernetes API to your IP. Workers join through the internal load balancer's private address. k3s calls the control-plane node a server and the worker an agent; the Terraform resources use the same names. [Design and limits](docs/design.md) explains why there are only two nodes and what a single etcd node means.

## Always Free budget

| Resource | Free allowance | This module |
|---|---|---|
| A1.Flex compute | 2 OCPUs / 12 GB / 2 instances | 1 server + 1 worker = **2 OCPUs / 12 GB** |
| Block storage | 200 GB | 2 × 100 GB = **200 GB** (boot volume IOPS scale with size) |
| Network Load Balancer | 1 | **1** (public, HTTP/HTTPS) |
| Flexible Load Balancer | 1 × 10 Mbps | **1** (private, kube-API). Tenancies created before December 2020 may be billed for it: check the cost report after the first apply |
| E2.1.Micro instances | 2 | **0** (Bastion is the managed OCI Bastion Service) |
| NAT Gateway | 1 per VCN | **1** |
| Object Storage | 20 GB (Free Tier) / 10 GB (Pay As You Go) | **2 versioned buckets**: etcd snapshots, Longhorn backups |
| Vault | Software keys + 150 secrets | **2-10 secrets** ([list](docs/data.md#oci-vault-secrets)) |
| Volume backups | 5 | **2** (weekly, 1-week retention) |
| MySQL HeatWave | 1 DB system, 50 GB | **1**, opt-in (`enable_mysql`) |
| Budgets | Free | **1** tenancy budget with email alerts, opt-in ([spend alert](docs/design.md#spend-alert)) |

`checks.tf` warns at plan time when a setting would leave the allowance.

## Quick start

```bash
git clone https://github.com/mbologna/k3s-oci.git
cd k3s-oci
cp example/terraform.tfvars.example example/terraform.tfvars
$EDITOR example/terraform.tfvars
cd example && tofu init && tofu apply      # terraform works too
```

Then fetch a kubeconfig through OCI Bastion (on by default):

```bash
./get-kubeconfig.sh                                  # in example/
export KUBECONFIG=~/.kube/clusters/config_oci_k3s
kubectl get nodes
```

`tofu output kubeconfig_hint` prints the steps for your settings; [Cluster access](docs/access.md) covers SSH, direct kube-API access and a cluster CA that survives rebuilds. The `Justfile` ([just](https://github.com/casey/just)) wraps the common commands (`just apply`, `just kubeconfig`, `just ssh worker`, `just teardown-keep-data`).

To use the module from your own configuration, pin a release tag ([Releases](https://github.com/mbologna/k3s-oci/releases); [Versioning](docs/updates.md#versioning) says which bumps need changes on your side):

```hcl
module "k3s" {
  source = "github.com/mbologna/k3s-oci?ref=vX.Y.Z"
  # see example/main.tf for the full variable list
}
```

To run your own apps through Argo CD, fork the repository and point it at your fork ([Adding your own applications](docs/applications.md#adding-your-own-applications)).

## Limits

- The control plane is a single node with a single etcd member. If it fails, the cluster is down until the node returns or a new one restores the latest etcd snapshot ([Failure tolerance](docs/design.md#failure-tolerance)).
- Reboots and upgrades drain one node at a time but are not zero-downtime: single-replica pods restart elsewhere, and the Kubernetes API is down while the control plane reboots. Run two replicas spread across the nodes for anything that must stay up.
- The control plane is short of memory, not CPU; keep IO-heavy batch jobs on the worker ([Node roles and workload placement](docs/design.md#node-roles-and-workload-placement)).
- OCI reclaims Always Free instances that stay idle for 7 days; the installed stack keeps them busy enough ([Idle reclamation](docs/design.md#idle-reclamation)).

## Documentation

| Page | Contents |
|---|---|
| [Cluster access](docs/access.md) | kubeconfig, SSH, Bastion, stable cluster CA, NLB IP changes |
| [Deploying applications](docs/applications.md) | TLS at Traefik, HTTP and HTTPS examples, DNS, GitOps, private repositories |
| [Operating systems](docs/operating-systems.md) | Ubuntu, openSUSE Leap and Leap Immutable, Fedora CoreOS, image imports |
| [Updates, releases and CI](docs/updates.md) | patches and reboots, k3s upgrades, Renovate, versioning, the CI plan check |
| [State, secrets, backups and rebuilds](docs/data.md) | Terraform state, Vault secrets, etcd snapshots, Longhorn backups, teardown |
| [Design and limits](docs/design.md) | topology, failure tolerance, workload placement, memory budget, cost |
| [gitops/README.md](gitops/README.md) | the Argo CD applications and optional components |
| [AGENTS.md](AGENTS.md) | conventions and internals, for contributors and coding agents |

## License

MIT. See [LICENSE](LICENSE).

## Variables

<!-- BEGIN_TF_DOCS -->
_Auto-generated input/output reference is disabled for now (the CI job that kept it in sync can no longer push to this branch-protected main). Run `terraform-docs -c .terraform-docs.yml .` locally to regenerate, or see `vars.tf` / `output.tf` for the current source of truth._
<!-- END_TF_DOCS -->
