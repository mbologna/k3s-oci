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

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_argocd_chart_release"></a> [argocd\_chart\_release](#input\_argocd\_chart\_release) | ArgoCD Helm chart version (argo/argo-cd). Chart version maps 1:1 to an ArgoCD app version. | `string` | `"7.8.23"` | no |
| <a name="input_argocd_hostname"></a> [argocd\_hostname](#input\_argocd\_hostname) | Fully-qualified hostname for the ArgoCD UI IngressRoute (e.g. argocd.example.com). When set, a Traefik IngressRoute with a cert-manager TLS certificate is created. | `string` | `null` | no |
| <a name="input_argocd_image_updater_release"></a> [argocd\_image\_updater\_release](#input\_argocd\_image\_updater\_release) | ArgoCD Image Updater release to install (kubectl apply). | `string` | `"v0.16.0"` | no |
| <a name="input_availability_domain"></a> [availability\_domain](#input\_availability\_domain) | Availability domain name, e.g. 'Uocm:EU-FRANKFURT-1-AD-1' | `string` | n/a | yes |
| <a name="input_bastion_shape"></a> [bastion\_shape](#input\_bastion\_shape) | Shape for the bastion instance. VM.Standard.E2.1.Micro is Always Free. | `string` | `"VM.Standard.E2.1.Micro"` | no |
| <a name="input_boot_volume_size_in_gbs"></a> [boot\_volume\_size\_in\_gbs](#input\_boot\_volume\_size\_in\_gbs) | Boot volume size in GB. Max 50 GB per instance to stay within the 200 GB Always Free block storage budget. | `number` | `50` | no |
| <a name="input_certmanager_email_address"></a> [certmanager\_email\_address](#input\_certmanager\_email\_address) | Email address for Let's Encrypt ACME registration. Must be a real address. | `string` | n/a | yes |
| <a name="input_certmanager_release"></a> [certmanager\_release](#input\_certmanager\_release) | cert-manager release to install. | `string` | `"v1.16.3"` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Logical name for the cluster. Used in display names and freeform tags. | `string` | n/a | yes |
| <a name="input_compartment_ocid"></a> [compartment\_ocid](#input\_compartment\_ocid) | OCID of the compartment where all resources are created | `string` | n/a | yes |
| <a name="input_compute_shape"></a> [compute\_shape](#input\_compute\_shape) | OCI compute shape for k3s nodes | `string` | `"VM.Standard.A1.Flex"` | no |
| <a name="input_disable_ingress"></a> [disable\_ingress](#input\_disable\_ingress) | When true, no ingress controller is installed (disables Traefik and skips Traefik 2 install) | `bool` | `false` | no |
| <a name="input_enable_bastion"></a> [enable\_bastion](#input\_enable\_bastion) | Provision a bastion host using the VM.Standard.E2.1.Micro shape (Always Free, AMD).<br/>When enabled, k3s nodes are placed in a private subnet and the bastion is the only<br/>SSH entry point. Strongly recommended for production. | `bool` | `false` | no |
| <a name="input_enable_oci_logging"></a> [enable\_oci\_logging](#input\_enable\_oci\_logging) | Enable OCI Logging for cloud-init logs. Ships /var/log/k3s-cloud-init.log to OCI Logging Service via the Unified Monitoring Agent. | `bool` | `true` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment label (e.g. staging, production) | `string` | `"staging"` | no |
| <a name="input_expose_kubeapi"></a> [expose\_kubeapi](#input\_expose\_kubeapi) | Expose the Kubernetes API server via the public NLB (restricted to my\_public\_ip\_cidr) | `bool` | `false` | no |
| <a name="input_fault_domains"></a> [fault\_domains](#input\_fault\_domains) | Fault domains to spread the instance pool across | `list(string)` | <pre>[<br/>  "FAULT-DOMAIN-1",<br/>  "FAULT-DOMAIN-2",<br/>  "FAULT-DOMAIN-3"<br/>]</pre> | no |
| <a name="input_gitops_repo_url"></a> [gitops\_repo\_url](#input\_gitops\_repo\_url) | Git repository URL for the ArgoCD App of Apps (e.g. https://github.com/your-org/k3s-oci.git). Set this to your fork so ArgoCD pulls from the right repo. | `string` | `"https://github.com/mbologna/k3s-oci.git"` | no |
| <a name="input_http_lb_port"></a> [http\_lb\_port](#input\_http\_lb\_port) | n/a | `number` | `80` | no |
| <a name="input_https_lb_port"></a> [https\_lb\_port](#input\_https\_lb\_port) | n/a | `number` | `443` | no |
| <a name="input_ingress_controller"></a> [ingress\_controller](#input\_ingress\_controller) | 'traefik2' installs Traefik via Helm for full control over the release and values. | `string` | `"traefik2"` | no |
| <a name="input_ingress_controller_http_nodeport"></a> [ingress\_controller\_http\_nodeport](#input\_ingress\_controller\_http\_nodeport) | NodePort on workers that the ingress controller binds for HTTP traffic | `number` | `30080` | no |
| <a name="input_ingress_controller_https_nodeport"></a> [ingress\_controller\_https\_nodeport](#input\_ingress\_controller\_https\_nodeport) | NodePort on workers that the ingress controller binds for HTTPS traffic | `number` | `30443` | no |
| <a name="input_k3s_extra_worker_node"></a> [k3s\_extra\_worker\_node](#input\_k3s\_extra\_worker\_node) | When true, provisions one additional standalone worker instance (oci\_core\_instance).<br/>This is the recommended way to use the 4th Always Free A1.Flex OCPU without exceeding<br/>OCI instance pool limits per tenancy. Default topology: 3 servers (pool) + 1 extra worker. | `bool` | `true` | no |
| <a name="input_k3s_server_pool_size"></a> [k3s\_server\_pool\_size](#input\_k3s\_server\_pool\_size) | Number of k3s control-plane nodes in the instance pool. Use 3 for HA (etcd quorum). Must be an odd number >= 1. | `number` | `3` | no |
| <a name="input_k3s_subnet"></a> [k3s\_subnet](#input\_k3s\_subnet) | Subnet name used to derive the flannel interface. Leave 'default\_route\_table' to let k3s auto-detect. | `string` | `"default_route_table"` | no |
| <a name="input_k3s_version"></a> [k3s\_version](#input\_k3s\_version) | k3s version to install. 'latest' resolves the current stable release at plan time via the GitHub API. | `string` | `"latest"` | no |
| <a name="input_k3s_worker_pool_size"></a> [k3s\_worker\_pool\_size](#input\_k3s\_worker\_pool\_size) | Number of k3s worker nodes managed by an instance pool (can be 0). | `number` | `0` | no |
| <a name="input_kube_api_port"></a> [kube\_api\_port](#input\_kube\_api\_port) | Port the k3s API server listens on | `number` | `6443` | no |
| <a name="input_kured_end_time"></a> [kured\_end\_time](#input\_kured\_end\_time) | End of the kured maintenance window (UTC, HH:MM). Default 06:00 UTC = 08:00 CET / 09:00 CEST. | `string` | `"06:00"` | no |
| <a name="input_kured_reboot_days"></a> [kured\_reboot\_days](#input\_kured\_reboot\_days) | Days of the week on which kured may reboot nodes. Defaults to all days. | `list(string)` | <pre>[<br/>  "mon",<br/>  "tue",<br/>  "wed",<br/>  "thu",<br/>  "fri",<br/>  "sat",<br/>  "sun"<br/>]</pre> | no |
| <a name="input_kured_release"></a> [kured\_release](#input\_kured\_release) | kured Helm chart version. | `string` | `"5.5.1"` | no |
| <a name="input_kured_start_time"></a> [kured\_start\_time](#input\_kured\_start\_time) | Start of the kured maintenance window (UTC, HH:MM). Default 22:00 UTC = midnight CET / 01:00 CEST. | `string` | `"22:00"` | no |
| <a name="input_longhorn_hostname"></a> [longhorn\_hostname](#input\_longhorn\_hostname) | Fully-qualified hostname for the Longhorn UI IngressRoute (e.g. longhorn.example.com). When set, a Traefik IngressRoute with BasicAuth and a cert-manager TLS certificate is created. | `string` | `null` | no |
| <a name="input_longhorn_release"></a> [longhorn\_release](#input\_longhorn\_release) | Longhorn release to install. | `string` | `"v1.8.1"` | no |
| <a name="input_longhorn_ui_username"></a> [longhorn\_ui\_username](#input\_longhorn\_ui\_username) | Username for Longhorn UI BasicAuth (only used when longhorn\_hostname is set). | `string` | `"admin"` | no |
| <a name="input_my_public_ip_cidr"></a> [my\_public\_ip\_cidr](#input\_my\_public\_ip\_cidr) | Your workstation public IP in CIDR notation (e.g. 1.2.3.4/32).<br/>Used to restrict bastion SSH access (when enable\_bastion = true) and<br/>kubeapi access via the public NLB (when expose\_kubeapi = true).<br/>k3s nodes live in the private subnet — direct SSH to nodes always<br/>requires the bastion as a jump host regardless of this setting. | `string` | n/a | yes |
| <a name="input_oci_cli_version"></a> [oci\_cli\_version](#input\_oci\_cli\_version) | OCI CLI version installed on control-plane nodes for first-server detection. | `string` | `"3.52.0"` | no |
| <a name="input_oci_core_vcn_cidr"></a> [oci\_core\_vcn\_cidr](#input\_oci\_core\_vcn\_cidr) | CIDR block for the VCN | `string` | `"10.0.0.0/16"` | no |
| <a name="input_oci_core_vcn_dns_label"></a> [oci\_core\_vcn\_dns\_label](#input\_oci\_core\_vcn\_dns\_label) | n/a | `string` | `"k3svcn"` | no |
| <a name="input_oci_identity_dynamic_group_name"></a> [oci\_identity\_dynamic\_group\_name](#input\_oci\_identity\_dynamic\_group\_name) | Name for the OCI dynamic group granting instances access to the OCI API | `string` | `"k3s-cluster-dynamic-group"` | no |
| <a name="input_oci_identity_policy_name"></a> [oci\_identity\_policy\_name](#input\_oci\_identity\_policy\_name) | Name for the OCI IAM policy attached to the dynamic group | `string` | `"k3s-cluster-policy"` | no |
| <a name="input_os_image_id"></a> [os\_image\_id](#input\_os\_image\_id) | OCID of the Ubuntu 24.04 LTS (Noble) image for A1.Flex and E2.1.Micro instances. Find OCIDs at https://docs.oracle.com/en-us/iaas/images/ | `string` | n/a | yes |
| <a name="input_private_subnet_cidr"></a> [private\_subnet\_cidr](#input\_private\_subnet\_cidr) | CIDR for the private subnet (k3s nodes) | `string` | `"10.0.1.0/24"` | no |
| <a name="input_private_subnet_dns_label"></a> [private\_subnet\_dns\_label](#input\_private\_subnet\_dns\_label) | n/a | `string` | `"k3sprivate"` | no |
| <a name="input_public_key"></a> [public\_key](#input\_public\_key) | SSH public key content placed on every instance. Preferred over public\_key\_path —<br/>pass the key string directly for CI pipelines where ~/.ssh does not exist.<br/>When null, the key is read from public\_key\_path at plan time. | `string` | `null` | no |
| <a name="input_public_key_path"></a> [public\_key\_path](#input\_public\_key\_path) | Path to SSH public key file. Used as fallback when public\_key is null. | `string` | `"~/.ssh/id_rsa.pub"` | no |
| <a name="input_public_subnet_cidr"></a> [public\_subnet\_cidr](#input\_public\_subnet\_cidr) | CIDR for the public subnet (load balancers and optional bastion) | `string` | `"10.0.0.0/24"` | no |
| <a name="input_public_subnet_dns_label"></a> [public\_subnet\_dns\_label](#input\_public\_subnet\_dns\_label) | n/a | `string` | `"k3spublic"` | no |
| <a name="input_server_memory_in_gbs"></a> [server\_memory\_in\_gbs](#input\_server\_memory\_in\_gbs) | RAM in GB per control-plane node. Total RAM must not exceed 24 GB (Always Free). | `number` | `6` | no |
| <a name="input_server_ocpus"></a> [server\_ocpus](#input\_server\_ocpus) | OCPUs per control-plane node. Total OCPUs across all nodes must not exceed 4 (Always Free). | `number` | `1` | no |
| <a name="input_tenancy_ocid"></a> [tenancy\_ocid](#input\_tenancy\_ocid) | OCID of the tenancy | `string` | n/a | yes |
| <a name="input_unique_tag_key"></a> [unique\_tag\_key](#input\_unique\_tag\_key) | Freeform tag key applied to every resource for identification | `string` | `"k3s-provisioner"` | no |
| <a name="input_unique_tag_value"></a> [unique\_tag\_value](#input\_unique\_tag\_value) | Freeform tag value applied to every resource for identification | `string` | `"https://github.com/mbologna/k3s-oci"` | no |
| <a name="input_worker_memory_in_gbs"></a> [worker\_memory\_in\_gbs](#input\_worker\_memory\_in\_gbs) | RAM in GB per worker node. | `number` | `6` | no |
| <a name="input_worker_ocpus"></a> [worker\_ocpus](#input\_worker\_ocpus) | OCPUs per worker node. | `number` | `1` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_argocd_initial_password_hint"></a> [argocd\_initial\_password\_hint](#output\_argocd\_initial\_password\_hint) | Command to retrieve the ArgoCD initial admin password (run after cluster is up) |
| <a name="output_bastion_public_ip"></a> [bastion\_public\_ip](#output\_bastion\_public\_ip) | Public IP of the bastion host (null if enable\_bastion = false) |
| <a name="output_internal_lb_ip"></a> [internal\_lb\_ip](#output\_internal\_lb\_ip) | Private IP of the internal load balancer (used by agents to join the cluster) |
| <a name="output_k3s_extra_worker_private_ip"></a> [k3s\_extra\_worker\_private\_ip](#output\_k3s\_extra\_worker\_private\_ip) | Private IP of the standalone extra worker node |
| <a name="output_k3s_servers_private_ips"></a> [k3s\_servers\_private\_ips](#output\_k3s\_servers\_private\_ips) | Private IPs of k3s control-plane nodes |
| <a name="output_k3s_token"></a> [k3s\_token](#output\_k3s\_token) | k3s cluster join token (sensitive) |
| <a name="output_k3s_workers_private_ips"></a> [k3s\_workers\_private\_ips](#output\_k3s\_workers\_private\_ips) | Private IPs of k3s worker nodes (instance pool) |
| <a name="output_kubeconfig_hint"></a> [kubeconfig\_hint](#output\_kubeconfig\_hint) | How to retrieve kubeconfig after cluster is up |
| <a name="output_longhorn_ui_credentials"></a> [longhorn\_ui\_credentials](#output\_longhorn\_ui\_credentials) | Longhorn UI credentials (only set when longhorn\_hostname is configured) |
| <a name="output_oci_log_group_id"></a> [oci\_log\_group\_id](#output\_oci\_log\_group\_id) | OCI Log Group OCID for k3s cloud-init logs (null if enable\_oci\_logging = false) |
| <a name="output_public_nlb_ip"></a> [public\_nlb\_ip](#output\_public\_nlb\_ip) | Public IP address of the NLB (point your DNS here) |
<!-- END_TF_DOCS -->

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
