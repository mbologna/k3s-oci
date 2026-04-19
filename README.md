# k3s-oci

[![CI](https://github.com/mbologna/k3s-oci/actions/workflows/terraform.yml/badge.svg)](https://github.com/mbologna/k3s-oci/actions/workflows/terraform.yml)

A production-ready [k3s](https://k3s.io) Terraform module for the [OCI Always Free tier](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm).

## Architecture

```
                    ┌─────────────────────────────────┐
Internet            │         OCI Region (home)        │
    │               │                                   │
    ▼               │  Public Subnet (10.0.0.0/24)     │
┌───────┐           │  ┌──────────┐  ┌──────────────┐ │
│  DNS  │──────────▶│  │ Public   │  │  Bastion     │ │
└───────┘  :80/:443 │  │  NLB    │  │ E2.1.Micro   │ │
                    │  └────┬─────┘  │ (optional)   │ │
                    │       │NodePort└──────┬───────┘ │
                    │       ▼               │SSH      │
                    │  Private Subnet (10.0.1.0/24)   │
                    │  ┌──────────────────────────┐   │
                    │  │   k3s servers (×3 HA)    │   │
                    │  │   A1.Flex 1 OCPU / 6 GB  │◀──┘
                    │  │   etcd quorum: 2/3 alive  │
                    │  └──────────┬───────────────┘
                    │     :6443   │  Internal LB
                    │  ┌──────────▼───────────────┐
                    │  │   k3s worker (×1 extra)  │
                    │  │   A1.Flex 1 OCPU / 6 GB  │
                    │  └──────────────────────────┘
                    └─────────────────────────────────┘
```

## Always Free budget

| Resource | Free allowance | This module |
|---|---|---|
| A1.Flex compute | 4 OCPUs / 24 GB / 4 instances | 3 servers + 1 worker = **4 OCPUs / 24 GB** |
| Block storage | 200 GB | 4 × 50 GB = **200 GB** |
| Network Load Balancer | 1 NLB | **1** (public, HTTP/HTTPS) |
| Flexible Load Balancer | 2 × 10 Mbps | **1** (private, kubeapi) |
| E2.1.Micro instances | 2 | **0–1** (optional bastion) |
| NAT Gateway | 1 per VCN (Always Free) | **1** (outbound-only for private nodes) |

> ⚠️ **Idle reclamation** <a name="-idle-reclamation"></a>: OCI reclaims Always Free instances where CPU, network, and memory stay below 20% for 7 consecutive days. The full stack (Longhorn, ArgoCD, cert-manager, kured) generates enough background activity to keep the cluster alive.

## Features

- **HA control plane** — 3 control-plane nodes with embedded etcd; survives 1 node failure
- **Full stack always deployed** — cert-manager, Longhorn, ArgoCD + Image Updater, and kured are always installed; they keep the cluster active and prevent [idle reclamation](#-idle-reclamation)
- **Separate public/private subnets** — k3s nodes have no public IP; only LBs and the optional bastion are internet-facing
- **Automatic security updates** — `unattended-upgrades` configured on every Ubuntu node; kured handles reboots
- **Graceful node reboots** — [kured](https://github.com/kubereboot/kured) drains and reboots nodes one at a time when a kernel update requires it
- **Ubuntu 24.04 LTS only** — a single, well-supported OS on aarch64; no multi-distro complexity
- **Traefik 2 ingress** — Helm-managed Traefik 2 (`traefik2`) with proxy-protocol support; built-in k3s Traefik also available (`traefik`)
- **k3s version pinned at plan time** — resolved from the GitHub API during `terraform plan`, not at boot time
- **Cluster-scoped IAM** — the OCI dynamic group and policy are scoped to nodes tagged with the cluster name, not every instance in the compartment
- **Idempotent cloud-init** — all `kubectl` operations use `apply`; re-provisioning is safe
- **CI / GitOps ready** — GitHub Actions for `fmt`/`validate`/ShellCheck; ArgoCD App of Apps under `gitops/`
- **Renovate** — `renovate.json` tracks Terraform provider updates and all inline-versioned dependencies via regex manager

## Quickstart

```bash
# 1. Clone and enter the example directory
git clone https://github.com/mbologna/k3s-oci.git
cd k3s-oci/example

# 2. Copy and edit the variables file
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 3. Init and apply
terraform init
terraform plan
terraform apply
```

## Variables

| Variable | Default | Description |
|---|---|---|
| `region` | — | OCI home region |
| `availability_domain` | — | Availability domain name |
| `tenancy_ocid` | — | Tenancy OCID |
| `compartment_ocid` | — | Compartment OCID |
| `cluster_name` | — | Logical cluster name (used in tags and display names) |
| `os_image_id` | — | Ubuntu 24.04 LTS (Noble) image OCID for A1.Flex and E2.1.Micro |
| `my_public_ip_cidr` | — | Your workstation CIDR for SSH / kubeapi access |
| `certmanager_email_address` | — | Real email for Let's Encrypt ACME |
| `k3s_version` | `"latest"` | k3s version; resolved at `plan` time when `"latest"` |
| `k3s_server_pool_size` | `3` | Control-plane pool size (must be odd ≥ 1) |
| `k3s_worker_pool_size` | `0` | Worker instance pool size |
| `k3s_extra_worker_node` | `true` | Provision the 4th A1.Flex node as a standalone worker |
| `server_ocpus` | `1` | OCPUs per control-plane node |
| `server_memory_in_gbs` | `6` | RAM per control-plane node |
| `worker_ocpus` | `1` | OCPUs per worker node |
| `worker_memory_in_gbs` | `6` | RAM per worker node |
| `boot_volume_size_in_gbs` | `50` | Boot volume size (47–200 GB) |
| `enable_bastion` | `false` | Provision E2.1.Micro bastion in the public subnet |
| `expose_kubeapi` | `false` | Expose kubeapi via public NLB (restricted to `my_public_ip_cidr`) |
| `ingress_controller` | `"traefik"` | `traefik` (k3s built-in) or `traefik2` (Helm-managed) |
| `disable_ingress` | `false` | Skip all ingress installation |
| `certmanager_release` | `v1.16.3` | cert-manager release (always installed) |
| `longhorn_release` | `v1.8.1` | Longhorn release (always installed) |
| `argocd_release` | `v2.14.9` | ArgoCD release (always installed) |
| `argocd_image_updater_release` | `v0.16.0` | ArgoCD Image Updater release (always installed) |
| `kured_release` | `5.5.1` | kured Helm chart version (always installed) |

## kubeconfig

After `terraform apply`:

```bash
# If enable_bastion = true
ssh -J ubuntu@<bastion-ip> ubuntu@<first-server-private-ip> \
    "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s|https://127.0.0.1:6443|https://<public-nlb-ip>:6443|" \
  > ~/.kube/k3s-oci.yaml
export KUBECONFIG=~/.kube/k3s-oci.yaml
kubectl get nodes
```

The `kubeconfig_hint` Terraform output prints the exact command for your deployment.

## Automatic updates & reboots (unattended-upgrades + kured)

`unattended-upgrades` applies Ubuntu security patches daily and sets `/var/run/reboot-required` when a kernel update needs a reboot.

[kured](https://github.com/kubereboot/kured) watches every node for `/var/run/reboot-required` and, when found:
1. Acquires a cluster-wide lock (only one node reboots at a time)
2. Cordons + drains the node
3. Reboots
4. Waits for the node to return and uncordons it

This keeps the cluster fully patched with zero manual intervention and no concurrent downtime.

## Dependency updates (Renovate)

`renovate.json` is included and tracks:

| Source | What is updated |
|---|---|
| Terraform `required_providers` | OCI provider, hashicorp/http, hashicorp/cloudinit, hashicorp/random |
| `# renovate:` inline comments in `vars.tf` | k3s, cert-manager, Longhorn, ArgoCD, ArgoCD Image Updater, kured |

To enable: install the [Renovate GitHub App](https://github.com/apps/renovate) and allow access to this repository. Renovate will open PRs for any new releases automatically.

## GitOps — App of Apps

The `gitops/` directory contains ArgoCD `Application` manifests managed with the [App of Apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern).

After the cluster is running, bootstrap it:

```bash
kubectl apply -n argocd -f gitops/apps/app-of-apps.yaml
```

ArgoCD will then continuously reconcile every manifest under `gitops/apps/`. To add a new application, create an `Application` manifest there and push — ArgoCD syncs it automatically.

## Remote Terraform state (OCI Object Storage)

OCI Object Storage (20 GB Always Free) is ideal for storing Terraform state:

```hcl
terraform {
  backend "s3" {
    bucket                      = "terraform-state"
    key                         = "k3s-oci/terraform.tfstate"
    region                      = "eu-frankfurt-1"
    endpoint                    = "https://<namespace>.compat.objectstorage.<region>.oraclecloud.com"
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    force_path_style            = true
  }
}
```

## License

MIT
