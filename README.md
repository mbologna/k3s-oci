# k3s-oci

[![CI](https://github.com/mbologna/k3s-oci/actions/workflows/ci.yml/badge.svg)](https://github.com/mbologna/k3s-oci/actions/workflows/ci.yml)

A production-ready [k3s](https://k3s.io) Terraform module for the [OCI Always Free tier](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm).

## Features

- **Single control plane**: 1 control-plane node with embedded etcd + 1 standalone worker (OCI Always Free 2 OCPU / 12 GB limit)
- **Full stack always deployed**: cert-manager, Longhorn, ArgoCD + Image Updater, and kured are always installed; they keep the cluster active and prevent [idle reclamation](#-idle-reclamation)
- **Separate public/private subnets**: k3s nodes have no public IP; only LBs and the optional bastion are internet-facing
- **Envoy Gateway ingress (Gateway API)**: one Envoy proxy per node (DaemonSet) with `system-cluster-critical` priority; standard `HTTPRoute`/`Gateway` resources; real client IP preservation via NLB transparent mode
- **Automatic security updates**: `unattended-upgrades` + [kured](https://github.com/kubereboot/kured) drain-reboot-uncordon cycle; zero manual intervention (Ubuntu) or `zypper patch` systemd timers (openSUSE)
- **Configurable OS** (`os_family`): Ubuntu 26.04 LTS (default, OCI-native image auto-resolved) or openSUSE Leap 16.0 (custom-imported UEFI image via `scripts/import-opensuse-aarch64.sh`)
- **k3s version pinned at plan time**: resolved from the GitHub API during `terraform plan`, not at boot time
- **Compartment-scoped IAM**: the dynamic group matches instances in the cluster's compartment (tag matching breaks instance_principal for pool members), and the policy grants only narrow verbs (read instances, read secrets, push logs, write objects in the cluster bucket)
- **Idempotent cloud-init**: all `kubectl` operations use `apply`; re-provisioning is safe
- **Direct SSH via NLB** (`expose_ssh = true`): expose port 22 on the public NLB restricted to `my_public_ip_cidr`; eliminates the need for OCI Bastion sessions for day-to-day access
- **OCI Vault** (`enable_vault = true`): cluster secrets in a free software-protected OCI Vault; fetched at boot via instance_principal, not embedded in user-data
- **Boot volume backups** (`enable_backup = true`): weekly full backups, 1-week retention, within the 5-backup Always Free limit
- **etcd snapshots to Object Storage** (`enable_object_storage_state = true`, `enable_etcd_snapshots = true`): a versioned bucket holds the 6-hourly etcd snapshots and the first-server leader lock (not your Terraform state, see [Remote Terraform state](#remote-terraform-state-oci-object-storage))
- **Longhorn backups to Object Storage** (`enable_longhorn_backup = true`): a second versioned bucket; with `create_longhorn_backup_user = true` the module creates a bucket-scoped service user and cloud-init wires the BackupTarget and a daily backup job
- **Rebuild without data loss** (`just teardown-keep-data`): destroys the cluster but keeps the Vault and both buckets, then re-imports them so the next apply reuses them
- **MySQL HeatWave** (`enable_mysql = false`): opt-in Always Free MySQL DB in the private subnet; credentials pre-created as a Kubernetes Secret
- **External DNS** (`enable_external_dns = false`): automatic Cloudflare DNS record management from HTTPRoute hostnames
- **External Secrets** (`enable_external_secrets = false`): sync OCI Vault secrets into Kubernetes Secrets via instance_principal; no credentials to rotate

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
k3s-server · etcd · Envoy Gateway · Longhorn · user workloads"]

        W["worker-0  ·  A1.Flex (1 OCPU / 6 GB)
k3s-agent · Envoy Gateway · Longhorn · user workloads"]
    end

    NAT["🌍 NAT Gateway (Always Free)"]
    Bastion["🔐 OCI Bastion Service
optional · Always Free"]

    Internet -->|HTTP / HTTPS| NLB
    NLB -->|"Envoy Gateway NodePorts :30080 / :30443"| CP & W
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

Both A1.Flex instances live in a **private subnet** with no public IPs. Internet traffic enters exclusively through two Always Free load balancers.

> **k3s naming note:** k3s calls control-plane nodes "servers" (`k3s server`) and workers "agents" (`k3s agent`). Terraform resources follow k3s conventions (`server`/`worker`); in standard Kubernetes terminology these map to control-plane and worker nodes.

**Public NLB** forwards HTTP/HTTPS directly to Envoy Gateway NodePorts on both nodes. `is_preserve_source = true` preserves real client IPs at the hypervisor level. The NLB optionally exposes the Kubernetes API on port 6443, restricted to your IP.

**Internal Flex LB** provides a stable private VIP for the control-plane node. Workers join via this VIP; the optional public kubeapi listener on the NLB targets the server directly.

**Longhorn** runs on both nodes with `defaultReplicaCount=2`; each PVC is replicated across both nodes. Control-plane `NoSchedule` taints are removed after cluster init so user workloads schedule across both identically-sized nodes.

The server and worker run in different fault domains (`fault_domains` / `standalone_worker_fault_domain`). Why there are only two nodes and what a single etcd node means: see [Why this topology](#why-this-topology) and [Failure tolerance](#failure-tolerance).

## Quickstart

```bash
# 1. Clone the repo
git clone https://github.com/mbologna/k3s-oci.git
cd k3s-oci

# 2. Copy and edit the variables file
cp example/terraform.tfvars.example example/terraform.tfvars
$EDITOR example/terraform.tfvars

# 3. Init and apply (terraform or tofu both work)
cd example && tofu init && tofu apply
```

To consume the module from your own configuration, pin a release tag
(see [Releases](https://github.com/mbologna/k3s-oci/releases) and `CHANGELOG.md`):

```hcl
module "k3s" {
  source = "github.com/mbologna/k3s-oci?ref=v1.1.0" # x-release-please-version
  # ... see example/main.tf for the full variable list
}
```

A `Justfile` is included for common operations (requires [just](https://github.com/casey/just)):

```bash
just init        # tofu init in example/
just plan        # tofu plan in example/
just apply       # tofu apply in example/
just kubeconfig  # fetch kubeconfig via OCI Bastion or the NLB (expose_ssh)
just ssh worker  # SSH into a node (server/worker or a private IP)
just fmt         # tofu fmt -recursive
```

## kubeconfig

After `terraform apply`, run:

```bash
terraform output kubeconfig_hint
```

This prints the exact steps for your configuration. If `enable_bastion = true` (recommended), the fastest path is the included helper script:

```bash
cd example && ./get-kubeconfig.sh
export KUBECONFIG=~/.kube/clusters/config_oci_k3s   # override with KUBECONFIG_OUT=...
kubectl get nodes                                   # context: k3s-oci
```

> `enable_bastion` defaults to `true`. It uses OCI Bastion Service, a managed SSH proxy with no VM, no boot volume, and no cost. Without it, nodes are only reachable via OCI serial console (`terraform output kubeconfig_hint` explains all options).

> **Direct SSH (no Bastion):** set `expose_ssh = true` to expose port 22 on the public NLB, restricted to `my_public_ip_cidr`. After apply:
> ```bash
> $(terraform output -raw ssh_command)
> ```
> This is faster than Bastion sessions and avoids session TTLs. When using `expose_ssh = true` you can set `enable_bastion = false` to skip the Bastion Service resource entirely.

### Stable cluster CA across rebuilds

Every `--cluster-init` normally generates a new cluster CA, so kubeconfigs stored elsewhere
(a password manager, dotfiles) stop working after a rebuild. To keep them valid, store the CA
in OCI Vault and set `k3s_ca_vault_secret_id` (requires `enable_vault = true`):

```bash
# on a running server: export the current CA, so existing kubeconfigs keep working
sudo tar -czf - -C /var/lib/rancher/k3s/server/tls \
  server-ca.crt server-ca.key client-ca.crt client-ca.key | base64 -w0 > k3s-ca.b64
# create a Vault secret whose value is the content of k3s-ca.b64, then:
#   k3s_ca_vault_secret_id = "<secret OCID>"
```

The first server extracts the four files before `--cluster-init`. k3s reuses existing CA files
instead of generating them, so the cluster keeps the same CA. If the secret is set but cannot
be fetched or extracted, cloud-init aborts instead of minting a new CA. Admin client certs
signed by `client-ca` (with `O=system:masters`) then survive rebuilds. The secret is created
outside the module, so `tofu destroy` never deletes it.

Setting it on an existing cluster takes effect at the next full rebuild: instance configurations
ignore `user_data` changes, so a server the pool relaunches meanwhile still boots without it.

## Deploying a web application

### Why TLS is terminated at Envoy Gateway, not at the OCI load balancer

OCI provides two load balancer products with very different capabilities:

| | OCI Network Load Balancer (NLB) | OCI Flexible Load Balancer |
|---|---|---|
| OSI layer | **L4 (TCP passthrough)** | L7 (HTTP/HTTPS aware) |
| TLS termination | ❌ Not possible | ✅ Yes |
| Always Free | **1 NLB** | 1 × 10 Mbps |
| Used here | `nlb.tf`: public internet traffic | `lb.tf`: internal kubeapi endpoint |

The public-facing load balancer is the **NLB**. It forwards raw TCP streams with `protocol = "TCP"`, so it has no knowledge of TLS, HTTP headers, or certificates. TLS **must** be terminated by something behind it.

The **Flexible LB** *could* terminate TLS, but the one free allocation is already consumed by the internal kubeapi load balancer. Even if it were available, using OCI to manage certificates would break the automatic cert-manager + Let's Encrypt renewal cycle.

The current flow is: Internet → NLB (TCP passthrough, preserves client IPs) → Envoy Gateway NodePort → TLS terminate → route to app pod.

### Minimal example: HTTP-only

No domain needed. Requests to the NLB IP are served directly.

```yaml
# hello-web.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-web
  namespace: hello-web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello-web
  template:
    metadata:
      labels:
        app: hello-web
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: hello-web
      containers:
        - name: hello-web
          image: httpd:alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: hello-web
  namespace: hello-web
spec:
  selector:
    app: hello-web
  ports:
    - port: 80
      targetPort: 80
---
# HTTPRoute — no hostname filter = matches all requests on the http listener
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hello-web
  namespace: hello-web
spec:
  parentRefs:
    - name: eg
      namespace: envoy-gateway-system
      sectionName: http
  rules:
    - backendRefs:
        - name: hello-web
          port: 80
```

```bash
kubectl create namespace hello-web
kubectl apply -f hello-web.yaml
NLB_IP=$(cd example && tofu output -raw nlb_ip)
curl http://$NLB_IP/
```

### Minimal example: HTTPS with sslip.io (no domain purchase required)

[sslip.io](https://sslip.io) is a public DNS service that resolves `<anything>.<ip>.sslip.io` directly to `<ip>`. Combined with cert-manager + Let's Encrypt HTTP-01, this gives a trusted TLS certificate with zero infrastructure cost.

Replace `<NLB_IP>` with the value of `tofu output -raw nlb_ip`.

```yaml
# hello-web-tls.yaml
---
# 1. Certificate — cert-manager issues this via HTTP-01 challenge through Envoy Gateway
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: hello-web-tls
  namespace: envoy-gateway-system   # must be in the same namespace as the Gateway
spec:
  secretName: hello-web-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - hello-web.<NLB_IP>.sslip.io
---
# 2. HTTPS listener on the Gateway (add this to gitops/gateway/gateway.yaml for GitOps management)
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: envoy-gateway-system
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
    - name: https-hello-web
      port: 443
      protocol: HTTPS
      hostname: hello-web.<NLB_IP>.sslip.io
      tls:
        mode: Terminate
        certificateRefs:
          - name: hello-web-tls
      allowedRoutes:
        namespaces:
          from: All
---
# 3. HTTP→HTTPS redirect (add hostname to gitops/gateway/redirect.yaml)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-to-https-redirect
  namespace: envoy-gateway-system
spec:
  parentRefs:
    - name: eg
      sectionName: http
  hostnames:
    - hello-web.<NLB_IP>.sslip.io
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
---
# 4. HTTPRoute for the app — attaches to both listeners
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hello-web
  namespace: hello-web
spec:
  parentRefs:
    - name: eg
      namespace: envoy-gateway-system
      sectionName: https-hello-web
  hostnames:
    - hello-web.<NLB_IP>.sslip.io
  rules:
    - backendRefs:
        - name: hello-web
          port: 80
```

```bash
# Wait for certificate issuance (typically 1–2 minutes)
kubectl wait --for=condition=Ready certificate/hello-web-tls -n envoy-gateway-system --timeout=5m
curl https://hello-web.<NLB_IP>.sslip.io/
```

> **With a real domain**: set `enable_external_dns = true` and annotate the HTTPRoute with
> `external-dns.alpha.kubernetes.io/hostname: myapp.example.com`. External DNS will create
> the A record automatically, then cert-manager issues the certificate. Alternatively,
> set `enable_dns01_challenge = true` to use DNS-01 (supports wildcard certs and does not
> require inbound port 80).

### Resilience: spread replicas across nodes

Run `replicas ≥ 2` with `topologySpreadConstraints` on `kubernetes.io/hostname` so losing one node never takes all replicas down. Envoy Gateway already runs on both nodes, so ingress survives a single-node drain or failure. See [gitops/README.md](gitops/README.md#resilience-spread-replicas-across-nodes) for the snippet and a matching PodDisruptionBudget.

## GitOps — App of Apps

The `gitops/` directory contains ArgoCD `Application` manifests managed with the [App of Apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern).

After the cluster is running, bootstrap it:

```bash
kubectl apply -n argocd -f gitops/apps/app-of-apps.yaml
```

ArgoCD will then continuously reconcile every manifest under `gitops/apps/`.

### Adding your own applications

This repo is designed to be forked. To add your own apps on top of the built-in stack:

1. **Fork this repo** on GitHub.

2. **Update all `repoURL` references** to point to your fork:
   ```bash
   bash gitops/update-repo-url.sh https://github.com/your-org/your-fork.git
   git add gitops/ && git commit -m "chore: update gitops repoURL"
   git push
   ```

3. **Add your ArgoCD `Application` manifests** to `gitops/apps/` — ArgoCD syncs them automatically. Each app can point at any Helm chart registry or any Git repository.

> **Deploying for the first time?** Also set `gitops_repo_url` in `terraform.tfvars` before running `tofu apply`, so cloud-init writes the correct fork URL at bootstrap:
> ```hcl
> gitops_repo_url = "https://github.com/your-org/your-fork.git"
> ```
> **Already have a running cluster?** Patch the App of Apps directly:
> ```bash
> argocd app set app-of-apps --repo https://github.com/your-org/your-fork.git
> ```

> **Private repos**: two auth methods, both storing the credential in OCI Vault automatically so cloud-init can create the `argocd-repo-gitops` Secret before ArgoCD starts. No manual `argocd repo add` step needed.
>
> - **SSH** — set `gitops_ssh_private_key` with your deploy key.
> - **HTTPS token** — set `gitops_https_username` + `gitops_https_token` (read-only repository scope; ArgoCD never writes). Takes precedence over the SSH key when both are set.
>
> Prefer the HTTPS token if your git host throttles SSH per source IP. ArgoCD is a heavy SSH client — every Application opens its own `git ls-remote` — and the resulting connection bursts can trip such limits and stall GitOps entirely, with apps stuck reporting `sync.revision` as `HEAD` rather than a SHA. Codeberg does this; GitHub and GitLab generally do not.
>
> For repos with a non-standard directory layout, set `gitops_path` (default: `gitops/apps`).

## Automatic updates & reboots (unattended-upgrades + kured)

`unattended-upgrades` applies Ubuntu security patches daily and sets `/var/run/reboot-required` when a kernel update needs a reboot.

[kured](https://github.com/kubereboot/kured) watches every node for `/var/run/reboot-required` and, when found:
1. Acquires a cluster-wide lock (only one node reboots at a time)
2. Cordons + drains the node
3. Reboots
4. Waits for the node to return and uncordons it

This keeps the cluster fully patched with zero manual intervention and no concurrent downtime.

## Dependency updates (Renovate)

[Renovate](https://docs.renovatebot.com) tracks Terraform providers, k3s, all stack component versions (via `# renovate:` inline comments in `vars.tf` and `gitops/apps/*.yaml`), and GitHub Actions. Enable it on your fork with the [Renovate GitHub App](https://github.com/apps/renovate); `renovate.json` extends a shared preset you may want to replace with your own.

## Remote Terraform state (OCI Object Storage)

`enable_object_storage_state = true` (the default) creates the versioned `<cluster_name>-terraform-state`
bucket. **It holds etcd snapshots and the leader lock — do not store your Terraform state in it:**

- The nodes have `manage objects` on that bucket, and the state contains every cluster secret
  (k3s token, Longhorn UI password, OAuth secrets, …). A compromised node could read it.
- `scripts/clean-oci-resources.sh` and `tofu destroy` delete the bucket together with the cluster.

Keep the state in a separate bucket, created outside this module, that the nodes have no IAM grant on:

```bash
oci os bucket create -c <compartment_ocid> --name <cluster_name>-tofu-state \
  --versioning Enabled --public-access-type NoPublicAccess
```

Then point the S3 backend at it from a gitignored `backend_override.tf` next to your module call
(`*_override.tf` is already in this repo's `.gitignore`):

```hcl
terraform {
  backend "s3" {
    bucket                      = "<cluster_name>-tofu-state"
    key                         = "terraform.tfstate"
    region                      = "<your-region>"                     # e.g. eu-frankfurt-1
    profile                     = "oci-tofu-state"                    # ~/.aws/credentials
    endpoints                   = { s3 = "https://<namespace>.compat.objectstorage.<region>.oraclecloud.com" }
    use_path_style              = true
    use_lockfile                = true                                # OpenTofu >= 1.10 / Terraform >= 1.11
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}
```

Migrate an existing local state with `tofu init -migrate-state`, then check that `tofu plan` reports no changes.
The namespace is in `terraform output terraform_state_backend`.

> **S3 credentials are OCI Customer Secret Keys** (**Identity → Users → <user> → Customer Secret Keys**).
> A key is **not** scoped to a bucket: it carries every permission of the user it belongs to. A key that
> only lives on your laptop can belong to your own user. Any key stored *inside* the cluster (such as
> Longhorn backups) must belong to a dedicated service user. For Longhorn backups,
> `create_longhorn_backup_user = true` makes the module create one; see [Longhorn backups](#longhorn-backups). Put that user in a group whose policy is limited
> to one bucket: `Allow group <g> to manage objects in tenancy where target.bucket.name='<bucket>'`
> (plus `read buckets` with the same condition). New keys take about 5 minutes to work on the S3 endpoint.

## Longhorn backups

`enable_longhorn_backup = true` (the default) creates the `<cluster_name>-longhorn-backup` bucket.
Set `create_longhorn_backup_user = true` to wire backups end to end:

- The module creates an IAM user, a group and a policy, all named `<cluster_name>-longhorn-backup`. The policy
  allows only `read buckets` and `manage objects` on the backup bucket. The user can use Customer Secret
  Keys and nothing else.
- Terraform creates the user's Customer Secret Key. With `enable_vault = true` the secret half is
  stored in Vault as `<cluster_name>-longhorn-backup-secret-key` and fetched at boot, so it is never in user-data.
- Cloud-init creates `longhorn-backup-secret` and points the Longhorn `BackupTarget` at the bucket. It also
  applies two RecurringJobs for every volume in the `default` group:
  - `daily-backup`: cron `longhorn_backup_schedule`, default `30 0 * * *` UTC; keeps `longhorn_backup_retain` backups, default 7.
  - `weekly-snapshot-cleanup`.

Creating IAM users requires tenancy-level IAM permissions. Without them, keep `create_longhorn_backup_user = false`
and follow the `longhorn_backup_setup` output (or `just setup-longhorn-backup`).
`retain` is the only cleanup: do not add an age-based lifecycle rule on `backupstore/`. Expiring blocks
underneath Longhorn corrupts the incremental chain. Backups of deleted volumes are never pruned automatically.
Delete them in the Longhorn UI.

## Always Free budget

| Resource | Free allowance | This module |
|---|---|---|
| A1.Flex compute | 2 OCPUs / 12 GB / 2 instances | 1 server + 1 worker = **2 OCPUs / 12 GB** |
| Block storage | 200 GB | 2 × 100 GB = **200 GB** (boot volume IOPS scale with size — the full allowance goes to etcd/image/Longhorn IO) |
| Network Load Balancer | 1 NLB | **1** (public, HTTP/HTTPS) |
| Flexible Load Balancer | 1 × 10 Mbps | **1** (private, kubeapi) |
| E2.1.Micro instances | 2 | **0** (bastion uses OCI Bastion Service, managed, no VM) |
| NAT Gateway | 1 per VCN | **1** (outbound-only for private nodes) |
| Object Storage | 20 GB (Free Tier) / 10 GB (Pay As You Go) | **2 versioned buckets**: etcd snapshots + leader lock, and Longhorn PVC backups (`enable_object_storage_state`, `enable_longhorn_backup`) |
| Vault (shared) | Software keys + 150 secrets | **2–9 secrets** (`enable_vault = true`), see [OCI Vault secrets](#oci-vault-secrets) |
| Volume backups | 5 total | **2** (one per node, weekly, 1-week retention) (`enable_backup = true`) |
| MySQL HeatWave | 1 standalone DB, 50 GB | **1 DB system** in private subnet (`enable_mysql = false`, opt-in) |

### OCI Vault secrets

With `enable_vault = true` every cluster secret below lives in the Vault and nodes fetch it
at boot (instance_principal); with `enable_vault = false` it is passed in user-data instead.

| Secret name | Created when |
|---|---|
| `<cluster>-k3s-token` | always |
| `<cluster>-longhorn-ui-password` | always |
| `<cluster>-dockerhub-password` | `dockerhub_password` set |
| `<cluster>-gitops-ssh-key` | `gitops_ssh_private_key` set |
| `<cluster>-gitops-https-token` | `gitops_https_token` set |
| `<cluster>-cloudflare-api-token` | `cloudflare_api_token` set |
| `<cluster>-tailscale-oauth-client-id` | `enable_tailscale = true` |
| `<cluster>-tailscale-client-secret` | `enable_tailscale = true` |
| `<cluster>-longhorn-backup-secret-key` | `create_longhorn_backup_user = true` or `user_ocid` set |

`k3s_ca_vault_secret_id` points at a secret you create yourself (not module-managed); see
[Stable cluster CA across rebuilds](#stable-cluster-ca-across-rebuilds).

> ⚠️ **Idle reclamation** <a name="-idle-reclamation"></a>: OCI reclaims Always Free instances where CPU, network, and memory stay below 20% for 7 consecutive days. The full stack (Longhorn, ArgoCD, cert-manager, kured) generates enough background activity to keep the cluster alive.

## Failure tolerance

| Component | Tolerance | What happens on failure |
|---|---|---|
| **Worker node failure** | ✅ Full | Workloads reschedule to control-plane (taints removed); Longhorn (2 replicas) keeps storage up |
| **Control-plane failure** | ❌ None | Single etcd node — cluster becomes unavailable; restore from etcd snapshot |
| **HTTP/HTTPS ingress** | ✅ Worker loss | Envoy Gateway DaemonSet on control-plane keeps ingress up |
| **Kubernetes API** | ❌ CP loss | Single control-plane; ILB has no failover target |
| **PVC data (Longhorn)** | ✅ 1 node | 2 replicas across 2 nodes; 1 replica lost, 1 remains serving |
| **cert-manager** | ⚠️ Soft | Pod reschedules within minutes; TLS serving unaffected (certs live in Secrets); only new issuance/renewal is paused |
| **ArgoCD** | ⚠️ Soft | GitOps sync pauses until rescheduled; running workloads unaffected |
| **MySQL (if enabled)** | ❌ None | Always Free tier = single OCI-managed instance; no HA failover |

## Node roles and workload placement

Each A1.Flex instance has identical resources (1 OCPU / 6 GB RAM). The k3s role (server vs agent) affects which system processes run, not how much resource is available for workloads.

| What | control-plane-0 | worker-0 | Scheduling mechanism |
|---|:---:|:---:|---|
| **etcd** | ✅ | ❌ | k3s built-in; servers only |
| **Kubernetes API server** | ✅ | ❌ | k3s built-in; servers only |
| **Envoy Gateway** (ingress) | ✅ | ✅ | DaemonSet (1 pod per node) |
| **Longhorn** (storage daemon) | ✅ | ✅ | DaemonSet (1 pod per node) |
| **cert-manager** | ✅ | ✅ | Deployment: schedules on any node |
| **ArgoCD** | ✅ | ✅ | Deployment: schedules on any node |
| **kured** | ✅ | ✅ | DaemonSet (1 pod per node) |
| **User workloads** | ✅ | ✅ | No restrictions — schedules on both nodes |

> **Why control-plane runs user workloads:** with one worker, a tainted server would make that worker a single point of failure for every workload. k3s does not taint servers by default; cloud-init still removes any `control-plane`/`etcd` `NoSchedule` taint defensively. Keep IO-heavy batch jobs (CI runners, Renovate, image builds) off the server with a **required** `node-role.kubernetes.io/control-plane DoesNotExist` node affinity: they slow etcd's fsync on the shared boot volume.
>
> **Recommendation:** use `replicas ≥ 2` with [topologySpreadConstraints](#resilience-spread-replicas-across-nodes) to spread pods across nodes.

## Why this topology

OCI reduced the A1.Flex Always Free allocation in June 2026 from 4 OCPUs/24 GB to **2 OCPUs/12 GB** (max 2 instances). The result is 1 control-plane + 1 standalone worker — no etcd HA, but full use of the free allocation.

### Topology comparison

| Topology | etcd HA | Nodes for workloads | Effective RAM for workloads† | Assessment |
|---|:---:|:---:|:---:|---|
| **1 CP + 1 worker (this module)** | ❌ Single node | 2 (taints removed) | ~10 GB | **Only viable option** within 2 OCPU / 12 GB Always Free limit |
| 2 CP + 0 workers | ❌ 2-node etcd invalid | 2 | ~9 GB | 2-node etcd cannot form quorum; worse than 1 node |

†etcd + kubeapi consume ~300–500 MB RAM and ~100–200m CPU per control-plane node.

### Why not use the 2 free E2.1.Micro instances as extra workers?

Always Free also includes 2 AMD E2.1.Micro instances. They are not worth adding:

1. **1 GB RAM**: k3s agent + Longhorn DaemonSet alone consume ~700–800 MB, leaving ~200 MB for user workloads
2. **1/8 OCPU**: negligible compute; adds operational complexity for near-zero workload benefit

### Previously rejected alternatives

| Alternative | Why it was rejected |
|---|---|
| nginx stream proxy in front of Envoy Gateway | Extra latency and complexity; NLB already preserves source IPs directly |
| OCI Bastion VM (E2.1.Micro) | OCI Bastion Service provides managed SSH proxying for free with no VM, no OS to patch, and no boot volume consuming storage budget |
| Boot volumes < 50 GB | OCI hard minimum is 50 GB per shape; the default 2 × 100 GB uses the whole 200 GB free block storage allowance |
| Additional NLB for kubeapi | Only 1 NLB is Always Free; the existing NLB conditionally exposes port 6443 via `expose_kubeapi = true` |
| Oracle Linux or other distros as the base OS | Only Ubuntu 26.04 (default) and openSUSE Leap 16.0 have bootstrap code; see [Choosing an OS](#choosing-an-os) below |

### Choosing an OS

The module supports two OS families, selected via `os_family`:

| `os_family` | Image | Auto-resolved | SSH user | Auto-updates |
|---|---|---|---|---|
| `"ubuntu"` (default) | Ubuntu 26.04 LTS (Resolute Raccoon) aarch64 | ✅ Yes (latest OCI-native image) | `ubuntu` | `unattended-upgrades` + `needrestart` |
| `"opensuse"` | openSUSE Leap 16.0 Minimal VM aarch64 | ❌ No (must import and set `os_image_id`) | `sles` | `zypper patch` systemd timers |

#### Ubuntu (default)

No extra steps needed. The latest Ubuntu 26.04 LTS image for `VM.Standard.A1.Flex` is resolved automatically at plan time from the tenancy.

#### openSUSE Leap 16.0

OCI has no native openSUSE image. Use the included script to import one before running `tofu apply`:

```bash
./scripts/import-opensuse-aarch64.sh
```

The script:
1. Resolves the latest openSUSE Leap 16.0 Minimal VM Cloud aarch64 QCOW2 from `download.opensuse.org`
2. Streams the image (~271 MiB) directly into a temporary OCI Object Storage bucket — no local disk required
3. Imports via the OCI REST API with `firmware: UEFI_64` and `launchMode: CUSTOM`
   (the OCI CLI's `oci compute image import` always defaults to BIOS; `UEFI_64` is required for `VM.Standard.A1.Flex`)
4. Adds `VM.Standard.A1.Flex` shape compatibility
5. Cleans up the temp Object Storage object
6. Prints the image OCID

Then set in `terraform.tfvars`:

```hcl
os_family   = "opensuse"
os_image_id = "ocid1.image.oc1..."   # OCID printed by the script above
```

**Script options:**

```
--compartment-id OCID   Compartment OCID (default: tenancy root)
--region REGION         OCI region (default: from ~/.oci/config)
--leap-version VERSION  openSUSE Leap version (default: 16.0)
--bucket-name NAME      Temp bucket name (default: opensuse-image-import-tmp)
--keep-bucket           Do not delete the QCOW2 object after import
--image-name NAME       Custom display name for the imported image
```

**Prerequisites:** OCI CLI configured (`~/.oci/config`), `curl`, `python3`.

**Known caveats (verified with Leap 16.0 + VM.Standard.A1.Flex):**

| Caveat | Detail |
|---|---|
| **Image must be re-imported on new Leap releases** | No auto-update path for the base OS image; re-run the script and update `os_image_id` when a new build is published |
| **UEFI_64 required at import time** | OCI's `oci compute image import` CLI hard-codes `firmware: BIOS`. The script works around this via a direct REST API call |
| **Shape compatibility not auto-detected** | OCI does not auto-detect the architecture of imported QCOW2 images; the script adds `VM.Standard.A1.Flex` explicitly |
| **Oracle Cloud Agent (OCA) unavailable** | No OCI-native monitoring agent on custom images |

#### Using any other OS image

Set `os_image_id` to the OCID of any OCI image. **Only Ubuntu and openSUSE are tested.** Any other OS will need its own bootstrap logic — fork the repo and adapt `files/lib/bootstrap-ubuntu.sh` as a starting point.


## Teardown

To delete the cluster and all associated OCI resources:

```bash
cd example
tofu destroy
```

> **Buckets:** `<cluster>-terraform-state` (etcd snapshots) and `<cluster>-longhorn-backup` (Longhorn backups)
> are module resources. OCI refuses to delete a non-empty bucket, so `tofu destroy` fails on them while they hold data.
> `scripts/clean-oci-resources.sh` empties and deletes them.
>
> **To rebuild without losing snapshots and backups**, use `scripts/teardown-keep-data.sh` instead of `tofu destroy`.
> It keeps the vault, its key and secrets, and both buckets, and puts them back into the state afterwards:
>
> ```bash
> COMPARTMENT_OCID=ocid1.tenancy.oc1..xxx CLUSTER_NAME=mycluster just teardown-keep-data
> # TF_DIR=path/to/root-module, CLEAN_CMD="bash my-wrapper.sh" optional;
> # IMPORT_ONLY=true resumes after a failed re-import
> just apply
> ```
>
> The script runs `state rm` on the kept resources, then `tofu destroy`, then the clean script with
> `KEEP_VAULT=true KEEP_BUCKETS=true`. Then it cancels pending vault and secret deletions and re-imports everything.
> Keep your Terraform state in a separate, module-external bucket (see [Remote Terraform state](#remote-terraform-state-oci-object-storage)) so teardown never touches it.

### After a rebuild that kept the buckets

- **Expected warning:** the new server finds the old cluster's etcd snapshots and logs
  `WARNING: etcd snapshots from a previous '<cluster>' cluster exist in ...` with the `k3s server --cluster-reset --cluster-reset-restore-path`
  restore steps. If you meant to start fresh, ignore it.
- **Restore window:** pruning keeps the newest `etcd_snapshot_retention` objects across the whole
  `etcd-snapshots/<cluster>/` prefix, so the new cluster's uploads push the old ones out. That takes
  `etcd_snapshot_retention` uploads, about 30 hours at the default retention of 5 and 6 hours between uploads.
  If you might need the old cluster's state later, copy its snapshots outside that prefix first
  (e.g. `oci os object copy` to `etcd-archive/`; it counts against the Object Storage allowance).
- **Longhorn backups** are not pruned by the new cluster. Restore PVCs from the Longhorn UI
  (**Backup → select → Restore**) or with a `Volume` that has `spec.fromBackup` set.

## NLB IP stability

The public NLB is never replaced by an ordinary `tofu apply`, so its IP is stable across applies.
It has `prevent_destroy = false` (so `tofu destroy` works for full rebuilds); if the NLB is **ever recreated** (destroy + apply, or `tofu state rm` + re-apply):

- All `sslip.io` hostnames change (e.g. `argocd.<old-ip>.sslip.io` → `argocd.<new-ip>.sslip.io`)
- Let's Encrypt certificates are invalid for the new hostnames and must be reissued
- With a custom domain + `enable_external_dns = true`, ExternalDNS updates DNS automatically and cert-manager auto-renews

**If using sslip.io defaults**, run `tofu apply` again after NLB recreation: `local.argocd_hostname` recomputes automatically from the new IP, cloud-init re-creates the Gateway listeners and certificates, and cert-manager reissues via Let's Encrypt.

## License

MIT. See [LICENSE](LICENSE).

## Variables

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_argocd_chart_version"></a> [argocd\_chart\_version](#input\_argocd\_chart\_version) | ArgoCD Helm chart version used for the bootstrap install. Must match gitops/apps/argocd.yaml targetRevision. Managed by Renovate. | `string` | `"10.9.5"` | no |
| <a name="input_argocd_hostname"></a> [argocd\_hostname](#input\_argocd\_hostname) | Fully-qualified hostname for the ArgoCD UI (e.g. argocd.example.com). When set, a Gateway API HTTPRoute with a cert-manager TLS certificate is created by cloud-init. If null, an sslip.io hostname is derived from the NLB IP. | `string` | `null` | no |
| <a name="input_availability_domain"></a> [availability\_domain](#input\_availability\_domain) | Availability domain name, e.g. 'Uocm:EU-FRANKFURT-1-AD-1' | `string` | n/a | yes |
| <a name="input_boot_volume_size_in_gbs"></a> [boot\_volume\_size\_in\_gbs](#input\_boot\_volume\_size\_in\_gbs) | Boot volume size in GB for k3s nodes (servers + workers). OCI minimum is 50 GB. Default 100 GB × 2 nodes = 200 GB, exactly the Always Free block storage limit. Boot volume performance scales with size (Balanced: 60 IOPS/GB), and etcd fsync latency on the boot volume is the main stability limit of the server — so use the whole allowance. The bastion uses OCI Bastion Service — no VM, no boot volume. | `number` | `100` | no |
| <a name="input_certmanager_chart_version"></a> [certmanager\_chart\_version](#input\_certmanager\_chart\_version) | cert-manager Helm chart version used for the bootstrap install. Must match gitops/apps/cert-manager.yaml targetRevision. Managed by Renovate. | `string` | `"v1.21.2"` | no |
| <a name="input_certmanager_email_address"></a> [certmanager\_email\_address](#input\_certmanager\_email\_address) | Email address for Let's Encrypt ACME registration. Must be a real address. | `string` | n/a | yes |
| <a name="input_cloudflare_api_token"></a> [cloudflare\_api\_token](#input\_cloudflare\_api\_token) | Cloudflare API token. Required when enable\_external\_dns = true or enable\_dns01\_challenge = true. Create a scoped token at https://dash.cloudflare.com/profile/api-tokens with Zone:DNS:Edit permissions. | `string` | `null` | no |
| <a name="input_cloudflare_zone_id"></a> [cloudflare\_zone\_id](#input\_cloudflare\_zone\_id) | Cloudflare Zone ID for the managed domain. Required when enable\_external\_dns = true. | `string` | `null` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Logical name for the cluster. Used in display names and freeform tags. | `string` | n/a | yes |
| <a name="input_compartment_ocid"></a> [compartment\_ocid](#input\_compartment\_ocid) | OCID of the compartment where all resources are created | `string` | n/a | yes |
| <a name="input_compute_shape"></a> [compute\_shape](#input\_compute\_shape) | OCI compute shape for k3s nodes | `string` | `"VM.Standard.A1.Flex"` | no |
| <a name="input_create_longhorn_backup_user"></a> [create\_longhorn\_backup\_user](#input\_create\_longhorn\_backup\_user) | Create a dedicated IAM service user, group and policy (all named <cluster\_name>-longhorn-backup)<br/>that can only read/write the Longhorn backup bucket, plus a Customer Secret Key for it.<br/>Cloud-init then wires the Longhorn BackupTarget and default RecurringJobs automatically.<br/>Preferred over user\_ocid. Requires enable\_longhorn\_backup = true, region set, and<br/>permission to manage IAM users/groups in the tenancy. Mutually exclusive with user\_ocid. | `bool` | `false` | no |
| <a name="input_dockerhub_password"></a> [dockerhub\_password](#input\_dockerhub\_password) | Docker Hub access token (PAT) for ArgoCD OCI Helm chart pulls. Paired with dockerhub\_username. | `string` | `""` | no |
| <a name="input_dockerhub_username"></a> [dockerhub\_username](#input\_dockerhub\_username) | Docker Hub username for ArgoCD to authenticate when pulling OCI Helm charts (e.g. Envoy Gateway from registry-1.docker.io). If empty, anonymous pulls are attempted and may be rate-limited. Create a PAT at https://app.docker.com/settings/personal-access-tokens | `string` | `""` | no |
| <a name="input_enable_backup"></a> [enable\_backup](#input\_enable\_backup) | Enable weekly boot volume backups for all k3s nodes (Always Free: 5 total backups). With 2 nodes at weekly-1-week-retention there are at most 2 active backups. | `bool` | `true` | no |
| <a name="input_enable_bastion"></a> [enable\_bastion](#input\_enable\_bastion) | Provision an OCI Bastion Service resource (managed SSH proxy, Always Free, no storage).<br/>When enabled, a STANDARD bastion is created and associated with the private subnet.<br/>Use example/get-kubeconfig.sh to retrieve kubeconfig via a Bastion session.<br/>Strongly recommended; without it, nodes are reachable only via serial console. | `bool` | `true` | no |
| <a name="input_enable_dns01_challenge"></a> [enable\_dns01\_challenge](#input\_enable\_dns01\_challenge) | Configure cert-manager ClusterIssuers to use DNS-01 ACME challenge via Cloudflare instead of HTTP-01. Enables wildcard certificates (*.example.com) and works even without inbound port 80. Requires cloudflare\_api\_token. | `bool` | `false` | no |
| <a name="input_enable_etcd_snapshots"></a> [enable\_etcd\_snapshots](#input\_enable\_etcd\_snapshots) | Upload etcd snapshots to the OCI Object Storage state bucket every 6 hours using OCI CLI instance\_principal auth (no Customer Secret Keys required). Requires enable\_object\_storage\_state = true. Provides off-node etcd backup for split-brain recovery. | `bool` | `true` | no |
| <a name="input_enable_external_dns"></a> [enable\_external\_dns](#input\_enable\_external\_dns) | Deploy external-dns (kubernetes-sigs) configured for Cloudflare. Automatically creates/updates DNS A records when Services or Ingresses are annotated. Requires cloudflare\_api\_token and cloudflare\_zone\_id. | `bool` | `false` | no |
| <a name="input_enable_external_secrets"></a> [enable\_external\_secrets](#input\_enable\_external\_secrets) | Deploy the External Secrets Operator and create a ClusterSecretStore backed by OCI Vault (instance\_principal auth). Requires enable\_vault = true. Workloads can then create ExternalSecret resources to sync any OCI Vault secret into a Kubernetes Secret without hard-coding values. | `bool` | `false` | no |
| <a name="input_enable_longhorn_backup"></a> [enable\_longhorn\_backup](#input\_enable\_longhorn\_backup) | Provision a dedicated Always Free OCI Object Storage bucket for Longhorn PVC backups. Cloud-init automatically creates the backup credentials secret and wires the Longhorn BackupTarget when create\_longhorn\_backup\_user = true (or user\_ocid is set). Shares the Object Storage free allowance (20 GB, or 10 GB on Pay As You Go) with the Terraform state bucket. | `bool` | `true` | no |
| <a name="input_enable_mysql"></a> [enable\_mysql](#input\_enable\_mysql) | Provision an Always Free MySQL HeatWave DB system (single node, 50 GB). Creates a Kubernetes Secret 'mysql-credentials' in the default namespace. | `bool` | `false` | no |
| <a name="input_enable_object_storage_state"></a> [enable\_object\_storage\_state](#input\_enable\_object\_storage\_state) | Provision an Always Free OCI Object Storage bucket for storing Terraform/OpenTofu state (S3-compatible API). See the terraform\_state\_backend output for the backend configuration snippet. | `bool` | `true` | no |
| <a name="input_enable_oci_logging"></a> [enable\_oci\_logging](#input\_enable\_oci\_logging) | Enable OCI Logging for cloud-init logs. Ships /var/log/k3s-cloud-init.log to OCI Logging Service via the Unified Monitoring Agent (Always Free: 10 GB/month). | `bool` | `true` | no |
| <a name="input_enable_tailscale"></a> [enable\_tailscale](#input\_enable\_tailscale) | Store Tailscale Kubernetes operator OAuth credentials in OCI Vault so the<br/>tailscale-operator ExternalSecret can sync them into the cluster without<br/>committing secrets to git. Requires enable\_vault = true.<br/>Pre-requisite: create an OAuth client at https://login.tailscale.com/admin/settings/oauth<br/>with scope Devices → Write (devices:core:write) and allowed tag tag:k8s-operator. | `bool` | `false` | no |
| <a name="input_enable_vault"></a> [enable\_vault](#input\_enable\_vault) | Store cluster secrets in OCI Vault (Always Free: software keys + 150 secrets): k3s\_token and longhorn\_ui\_password always, plus dockerhub/gitops/cloudflare/tailscale/longhorn-backup credentials when those are set (2-9 secrets, see README). Nodes fetch them via OCI CLI instance\_principal at boot, so plaintext values are removed from cloud-init user-data. | `bool` | `true` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment label (e.g. staging, production) | `string` | `"staging"` | no |
| <a name="input_etcd_snapshot_retention"></a> [etcd\_snapshot\_retention](#input\_etcd\_snapshot\_retention) | Number of etcd snapshots to retain in OCI Object Storage per node. Older snapshots are pruned automatically by the cron job. Must be >= 1 (0 would disable pruning and grow the bucket unbounded). | `number` | `5` | no |
| <a name="input_expose_kubeapi"></a> [expose\_kubeapi](#input\_expose\_kubeapi) | Expose the Kubernetes API server via the public NLB (restricted to my\_public\_ip\_cidr) | `bool` | `false` | no |
| <a name="input_expose_ssh"></a> [expose\_ssh](#input\_expose\_ssh) | Expose SSH (port 22) via the public NLB to all cluster nodes (restricted to my\_public\_ip\_cidr). Eliminates the need for OCI Bastion sessions for day-to-day access. | `bool` | `false` | no |
| <a name="input_external_dns_domain_filter"></a> [external\_dns\_domain\_filter](#input\_external\_dns\_domain\_filter) | Domain filter for external-dns — only DNS records under this domain are managed (e.g. 'k3s.example.com'). Required when enable\_external\_dns = true. | `string` | `null` | no |
| <a name="input_external_secrets_chart_version"></a> [external\_secrets\_chart\_version](#input\_external\_secrets\_chart\_version) | External Secrets Operator Helm chart version used for the bootstrap install. Must match gitops/apps/external-secrets.yaml targetRevision. Managed by Renovate. | `string` | `"2.10.0"` | no |
| <a name="input_fault_domains"></a> [fault\_domains](#input\_fault\_domains) | Fault domains to spread the instance pools across. FAULT-DOMAIN-2 is left out by default because it is reserved for the standalone worker (standalone\_worker\_fault\_domain), so the server and the worker never share hardware. | `list(string)` | <pre>[<br/>  "FAULT-DOMAIN-1",<br/>  "FAULT-DOMAIN-3"<br/>]</pre> | no |
| <a name="input_gateway_api_version"></a> [gateway\_api\_version](#input\_gateway\_api\_version) | Kubernetes Gateway API CRDs version (experimental channel) installed at bootstrap. Experimental channel is a superset of standard and includes GRPCRoute, TCPRoute, TLSRoute, etc. required by Envoy Gateway. Must exist before ArgoCD syncs gateway-config. | `string` | `"v1.6.2"` | no |
| <a name="input_github_ssh_keys_username"></a> [github\_ssh\_keys\_username](#input\_github\_ssh\_keys\_username) | GitHub username whose published SSH keys (https://github.com/<username>.keys)<br/>are added to every instance's authorized\_keys at plan time, in addition to<br/>the primary public\_key / public\_key\_path. Leave empty to skip. | `string` | `""` | no |
| <a name="input_gitops_https_token"></a> [gitops\_https\_token](#input\_gitops\_https\_token) | Access token (or password) for HTTPS auth against a PRIVATE gitops repo. Terraform stores it in OCI Vault; cloud-init fetches it and creates the argocd-repo-gitops Secret with username/password before ArgoCD starts. Grant read-only repository scope — ArgoCD never writes. Leave empty for SSH auth or a public HTTPS repo. | `string` | `""` | no |
| <a name="input_gitops_https_username"></a> [gitops\_https\_username](#input\_gitops\_https\_username) | Username for HTTPS auth against a PRIVATE gitops repo. Used with gitops\_https\_token. Leave empty for SSH auth or a public HTTPS repo. | `string` | `""` | no |
| <a name="input_gitops_path"></a> [gitops\_path](#input\_gitops\_path) | Path within gitops\_repo\_url that ArgoCD uses as the App of Apps source. Default is 'gitops/apps' (k3s-oci native layout). Override when your GitOps repo uses a different directory structure. | `string` | `"gitops/apps"` | no |
| <a name="input_gitops_repo_url"></a> [gitops\_repo\_url](#input\_gitops\_repo\_url) | Git repository URL for the ArgoCD App of Apps (e.g. https://github.com/your-org/k3s-oci.git). Set this to your fork so ArgoCD pulls from the right repo. | `string` | `"https://github.com/mbologna/k3s-oci.git"` | no |
| <a name="input_gitops_ssh_private_key"></a> [gitops\_ssh\_private\_key](#input\_gitops\_ssh\_private\_key) | SSH private key (PEM/OpenSSH format) for ArgoCD to clone the gitops repo. Terraform stores it in OCI Vault; cloud-init fetches it and creates the argocd-repo-gitops Secret before ArgoCD starts. Leave empty when using gitops\_https\_token (HTTPS auth takes precedence) or when gitops\_repo\_url is a public HTTPS repo. | `string` | `""` | no |
| <a name="input_http_lb_port"></a> [http\_lb\_port](#input\_http\_lb\_port) | Public HTTP port on the NLB frontend (default 80). | `number` | `80` | no |
| <a name="input_https_lb_port"></a> [https\_lb\_port](#input\_https\_lb\_port) | Public HTTPS port on the NLB frontend (default 443). | `number` | `443` | no |
| <a name="input_ingress_controller_http_nodeport"></a> [ingress\_controller\_http\_nodeport](#input\_ingress\_controller\_http\_nodeport) | NodePort on workers that the ingress controller binds for HTTP traffic | `number` | `30080` | no |
| <a name="input_ingress_controller_https_nodeport"></a> [ingress\_controller\_https\_nodeport](#input\_ingress\_controller\_https\_nodeport) | NodePort on workers that the ingress controller binds for HTTPS traffic | `number` | `30443` | no |
| <a name="input_k3s_ca_vault_secret_id"></a> [k3s\_ca\_vault\_secret\_id](#input\_k3s\_ca\_vault\_secret\_id) | OCID of an existing OCI Vault secret holding a base64 tar.gz of k3s CA files (server-ca.crt/.key, client-ca.crt/.key, paths relative to /var/lib/rancher/k3s/server/tls). When set, the first server seeds them before --cluster-init, so the cluster CA (and every kubeconfig signed by it) survives rebuilds. The secret is created outside this module. | `string` | `null` | no |
| <a name="input_k3s_extra_server_args"></a> [k3s\_extra\_server\_args](#input\_k3s\_extra\_server\_args) | Extra arguments appended to the k3s server install command. Useful for etcd tuning on resource-constrained nodes (e.g. ['--etcd-arg=election-timeout=5000', '--etcd-arg=heartbeat-interval=1000']). | `list(string)` | `[]` | no |
| <a name="input_k3s_server_pool_size"></a> [k3s\_server\_pool\_size](#input\_k3s\_server\_pool\_size) | Number of k3s control-plane nodes in the instance pool. Always Free allows only 1 (2 OCPUs / 12 GB total split with the standalone worker). Must be an odd number >= 1. | `number` | `1` | no |
| <a name="input_k3s_standalone_worker"></a> [k3s\_standalone\_worker](#input\_k3s\_standalone\_worker) | When true (default), provisions one worker node as a plain oci\_core\_instance resource.<br/>This is the recommended approach for OCI Always Free tenancies: instance pools route<br/>requests through OCI Capacity Management which can fail for A1.Flex shapes, whereas<br/>a direct oci\_core\_instance reliably claims the free allocation.<br/>Default topology: 1 control-plane node (pool) + 1 standalone worker = 2 OCPUs / 12 GB. | `bool` | `true` | no |
| <a name="input_k3s_subnet"></a> [k3s\_subnet](#input\_k3s\_subnet) | Subnet name used to derive the flannel interface. Leave 'default\_route\_table' to let k3s auto-detect. | `string` | `"default_route_table"` | no |
| <a name="input_k3s_version"></a> [k3s\_version](#input\_k3s\_version) | k3s version to install. Use 'stable' or 'latest' to resolve from the k3s channel API at plan-time, or pin to a specific release (e.g. 'v1.35.5+k3s1'). | `string` | `"stable"` | no |
| <a name="input_k3s_worker_pool_size"></a> [k3s\_worker\_pool\_size](#input\_k3s\_worker\_pool\_size) | Number of k3s worker nodes managed by the OCI Instance Pool.<br/>Set to 0 (default) when using k3s\_standalone\_worker = true, which is the recommended<br/>Always Free topology. The pool is kept to allow future scaling beyond the free tier. | `number` | `0` | no |
| <a name="input_kube_api_port"></a> [kube\_api\_port](#input\_kube\_api\_port) | Port the k3s API server listens on | `number` | `6443` | no |
| <a name="input_longhorn_backup_retain"></a> [longhorn\_backup\_retain](#input\_longhorn\_backup\_retain) | Number of backups per volume the default Longhorn `daily-backup` RecurringJob keeps. Longhorn deletes older backups (and their unreferenced blocks) from the bucket itself. Keep the bucket inside the Object Storage free allowance. | `number` | `7` | no |
| <a name="input_longhorn_backup_schedule"></a> [longhorn\_backup\_schedule](#input\_longhorn\_backup\_schedule) | Cron schedule (UTC) of the default Longhorn `daily-backup` RecurringJob created by cloud-init when the backup target is wired automatically. | `string` | `"30 0 * * *"` | no |
| <a name="input_longhorn_hostname"></a> [longhorn\_hostname](#input\_longhorn\_hostname) | Fully-qualified hostname for the Longhorn UI (e.g. longhorn.example.com). When set, a Gateway API HTTPRoute with BasicAuth (Envoy Gateway SecurityPolicy) and a cert-manager TLS certificate is created. | `string` | `null` | no |
| <a name="input_longhorn_ui_username"></a> [longhorn\_ui\_username](#input\_longhorn\_ui\_username) | Username for Longhorn UI BasicAuth (only used when longhorn\_hostname is set). | `string` | `"admin"` | no |
| <a name="input_my_public_ip_cidr"></a> [my\_public\_ip\_cidr](#input\_my\_public\_ip\_cidr) | Your workstation public IP(s) in CIDR notation (e.g. ["1.2.3.4/32"]).<br/>Restricts OCI Bastion Service session creation (enable\_bastion = true) and<br/>kubeapi access via the public NLB (expose\_kubeapi = true).<br/>k3s nodes are in a private subnet and are only reachable via OCI Bastion sessions.<br/>A list so multiple networks (e.g. home + travel) can be allowed at once. | `list(string)` | n/a | yes |
| <a name="input_mysql_admin_username"></a> [mysql\_admin\_username](#input\_mysql\_admin\_username) | Admin username for the MySQL HeatWave DB system. | `string` | `"admin"` | no |
| <a name="input_mysql_shape"></a> [mysql\_shape](#input\_mysql\_shape) | MySQL HeatWave shape. 'MySQL.Free' is the Always Free shape. | `string` | `"MySQL.Free"` | no |
| <a name="input_oci_core_vcn_cidr"></a> [oci\_core\_vcn\_cidr](#input\_oci\_core\_vcn\_cidr) | CIDR block for the VCN | `string` | `"10.0.0.0/16"` | no |
| <a name="input_oci_core_vcn_dns_label"></a> [oci\_core\_vcn\_dns\_label](#input\_oci\_core\_vcn\_dns\_label) | DNS label for the VCN (≤15 alphanumeric chars, no hyphens — OCI DNS constraint). | `string` | `"k3svcn"` | no |
| <a name="input_oci_identity_dynamic_group_name"></a> [oci\_identity\_dynamic\_group\_name](#input\_oci\_identity\_dynamic\_group\_name) | Name for the OCI dynamic group granting instances access to the OCI API.<br/>Must be unique per tenancy — the default 'k3s-cluster-dynamic-group' collides<br/>if you deploy multiple clusters in the same tenancy. Recommended: set to<br/>"<cluster\_name>-dynamic-group" in your tfvars. | `string` | `"k3s-cluster-dynamic-group"` | no |
| <a name="input_oci_identity_policy_name"></a> [oci\_identity\_policy\_name](#input\_oci\_identity\_policy\_name) | Name for the OCI IAM policy attached to the dynamic group.<br/>Must be unique per tenancy — the default 'k3s-cluster-policy' collides<br/>if you deploy multiple clusters in the same tenancy. Recommended: set to<br/>"<cluster\_name>-policy" in your tfvars. | `string` | `"k3s-cluster-policy"` | no |
| <a name="input_os_family"></a> [os\_family](#input\_os\_family) | OS distribution for cluster nodes. "ubuntu" (default) uses OCI-native Ubuntu 26.04 LTS and auto-resolves the latest image. "opensuse" uses openSUSE Leap 16.0 — requires os\_image\_id (use scripts/import-opensuse-aarch64.sh to import the image and obtain its OCID). | `string` | `"ubuntu"` | no |
| <a name="input_os_image_id"></a> [os\_image\_id](#input\_os\_image\_id) | OCID of the OS image for A1.Flex nodes. If null and os\_family = "ubuntu", the latest Ubuntu 26.04 aarch64 image is resolved automatically. Required when os\_family = "opensuse" — use scripts/import-opensuse-aarch64.sh to import and capture the OCID. | `string` | `null` | no |
| <a name="input_private_subnet_cidr"></a> [private\_subnet\_cidr](#input\_private\_subnet\_cidr) | CIDR for the private subnet (k3s nodes) | `string` | `"10.0.1.0/24"` | no |
| <a name="input_private_subnet_dns_label"></a> [private\_subnet\_dns\_label](#input\_private\_subnet\_dns\_label) | DNS label for the private subnet (≤15 alphanumeric chars, no hyphens — OCI DNS constraint). | `string` | `"k3sprivate"` | no |
| <a name="input_public_key"></a> [public\_key](#input\_public\_key) | SSH public key content placed on every instance. Preferred over public\_key\_path —<br/>pass the key string directly for CI pipelines where ~/.ssh does not exist.<br/>When null, the key is read from public\_key\_path at plan time. | `string` | `null` | no |
| <a name="input_public_key_path"></a> [public\_key\_path](#input\_public\_key\_path) | Path to SSH public key file. Used as fallback when public\_key is null. | `string` | `"~/.ssh/id_ed25519.pub"` | no |
| <a name="input_public_subnet_cidr"></a> [public\_subnet\_cidr](#input\_public\_subnet\_cidr) | CIDR for the public subnet (load balancers and optional bastion) | `string` | `"10.0.0.0/24"` | no |
| <a name="input_public_subnet_dns_label"></a> [public\_subnet\_dns\_label](#input\_public\_subnet\_dns\_label) | DNS label for the public subnet (≤15 alphanumeric chars, no hyphens — OCI DNS constraint). | `string` | `"k3spublic"` | no |
| <a name="input_region"></a> [region](#input\_region) | OCI region identifier (e.g. 'eu-frankfurt-1'). Required when enable\_external\_secrets = true for the ClusterSecretStore to locate the OCI Vault endpoint. | `string` | `null` | no |
| <a name="input_server_memory_in_gbs"></a> [server\_memory\_in\_gbs](#input\_server\_memory\_in\_gbs) | RAM in GB per control-plane node. Total RAM must not exceed 12 GB (Always Free). | `number` | `6` | no |
| <a name="input_server_ocpus"></a> [server\_ocpus](#input\_server\_ocpus) | OCPUs per control-plane node. Total OCPUs across all nodes must not exceed 2 (Always Free). | `number` | `1` | no |
| <a name="input_standalone_worker_fault_domain"></a> [standalone\_worker\_fault\_domain](#input\_standalone\_worker\_fault\_domain) | Fault domain for the standalone worker. Keep it out of var.fault\_domains so the worker and the server land on different physical hardware. Set to null to let OCI choose. | `string` | `"FAULT-DOMAIN-2"` | no |
| <a name="input_tailscale_oauth_client_id"></a> [tailscale\_oauth\_client\_id](#input\_tailscale\_oauth\_client\_id) | Tailscale OAuth client ID. Required when enable\_tailscale = true. | `string` | `null` | no |
| <a name="input_tailscale_oauth_client_secret"></a> [tailscale\_oauth\_client\_secret](#input\_tailscale\_oauth\_client\_secret) | Tailscale OAuth client secret. Required when enable\_tailscale = true. | `string` | `null` | no |
| <a name="input_tenancy_ocid"></a> [tenancy\_ocid](#input\_tenancy\_ocid) | OCID of the tenancy | `string` | n/a | yes |
| <a name="input_trace_enabled"></a> [trace\_enabled](#input\_trace\_enabled) | Enable bash trace mode (set -x) in cloud-init scripts. Produces verbose output in /var/log/k3s-cloud-init.log. Useful for debugging bootstrap failures. Do NOT enable in production. | `bool` | `false` | no |
| <a name="input_unique_tag_key"></a> [unique\_tag\_key](#input\_unique\_tag\_key) | Freeform tag key applied to every resource for identification | `string` | `"k3s-provisioner"` | no |
| <a name="input_unique_tag_value"></a> [unique\_tag\_value](#input\_unique\_tag\_value) | Freeform tag value applied to every resource for identification | `string` | `"https://github.com/mbologna/k3s-oci"` | no |
| <a name="input_user_ocid"></a> [user\_ocid](#input\_user\_ocid) | OCID of the user that owns the Longhorn backup S3 key (format: ocid1.user.oc1..xxx).<br/>The key ends up in the cluster and carries ALL of this user's rights, so use a<br/>dedicated service user whose policy is limited to the backup bucket, not an admin.<br/>Required when enable\_longhorn\_backup = true to automatically create a Customer<br/>Secret Key for S3-compatible access, wire the Longhorn backup credentials<br/>Kubernetes Secret, and apply the Longhorn BackupTarget in cloud-init.<br/>When null, the Longhorn backup bucket is still created but wiring is manual<br/>(follow the longhorn\_backup\_setup output instructions). | `string` | `null` | no |
| <a name="input_worker_memory_in_gbs"></a> [worker\_memory\_in\_gbs](#input\_worker\_memory\_in\_gbs) | RAM in GB per worker node. | `number` | `6` | no |
| <a name="input_worker_ocpus"></a> [worker\_ocpus](#input\_worker\_ocpus) | OCPUs per worker node. | `number` | `1` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_argocd_initial_password_hint"></a> [argocd\_initial\_password\_hint](#output\_argocd\_initial\_password\_hint) | Command to retrieve the ArgoCD initial admin password (run after cluster is up) |
| <a name="output_bastion_ocid"></a> [bastion\_ocid](#output\_bastion\_ocid) | OCID of the OCI Bastion Service resource (null if enable\_bastion = false). Use with example/get-kubeconfig.sh or oci bastion session create-managed-ssh. |
| <a name="output_internal_lb_ip"></a> [internal\_lb\_ip](#output\_internal\_lb\_ip) | Private IP of the internal load balancer (used by agents to join the cluster) |
| <a name="output_k3s_servers_private_ips"></a> [k3s\_servers\_private\_ips](#output\_k3s\_servers\_private\_ips) | Private IPs of k3s control-plane nodes |
| <a name="output_k3s_standalone_worker_private_ip"></a> [k3s\_standalone\_worker\_private\_ip](#output\_k3s\_standalone\_worker\_private\_ip) | Private IP of the standalone worker node (oci\_core\_instance, not pool-managed) |
| <a name="output_k3s_token"></a> [k3s\_token](#output\_k3s\_token) | k3s cluster join token (sensitive) |
| <a name="output_k3s_workers_private_ips"></a> [k3s\_workers\_private\_ips](#output\_k3s\_workers\_private\_ips) | Private IPs of k3s worker nodes (instance pool) |
| <a name="output_kubeconfig_hint"></a> [kubeconfig\_hint](#output\_kubeconfig\_hint) | How to retrieve kubeconfig after cluster is up |
| <a name="output_longhorn_backup_setup"></a> [longhorn\_backup\_setup](#output\_longhorn\_backup\_setup) | Longhorn backup bucket info and wiring status. Null if enable\_longhorn\_backup = false. |
| <a name="output_longhorn_ui_credentials"></a> [longhorn\_ui\_credentials](#output\_longhorn\_ui\_credentials) | Longhorn UI credentials (only set when longhorn\_hostname is configured) |
| <a name="output_mysql_admin_credentials"></a> [mysql\_admin\_credentials](#output\_mysql\_admin\_credentials) | MySQL HeatWave admin credentials (sensitive). Null if enable\_mysql = false. |
| <a name="output_mysql_endpoint"></a> [mysql\_endpoint](#output\_mysql\_endpoint) | MySQL HeatWave connection endpoint (hostname:port). Null if enable\_mysql = false. |
| <a name="output_oci_log_group_id"></a> [oci\_log\_group\_id](#output\_oci\_log\_group\_id) | OCI Log Group OCID for k3s cloud-init logs (null if enable\_oci\_logging = false) |
| <a name="output_public_nlb_ip"></a> [public\_nlb\_ip](#output\_public\_nlb\_ip) | Public IP address of the NLB (point your DNS here) |
| <a name="output_ssh_command"></a> [ssh\_command](#output\_ssh\_command) | SSH command to connect to a cluster node via the public NLB (null if expose\_ssh = false). Routes to any available server. |
| <a name="output_ssh_host_public_key"></a> [ssh\_host\_public\_key](#output\_ssh\_host\_public\_key) | Shared SSH host public key deployed to all nodes. Add to known\_hosts with: ssh-keygen -R <nlb-ip> && terraform output -raw ssh\_host\_public\_key \| ssh-keyscan -f - >> ~/.ssh/known\_hosts  (or simply ssh-keyscan <nlb-ip> >> ~/.ssh/known\_hosts after apply). |
| <a name="output_tailscale_vault_secret_names"></a> [tailscale\_vault\_secret\_names](#output\_tailscale\_vault\_secret\_names) | OCI Vault secret names for the Tailscale operator OAuth credentials (null if enable\_tailscale = false).<br/>Reference these names in the ExternalSecret (platform/<cluster>/tailscale-operator/oauth-secret.yaml). |
| <a name="output_terraform_state_backend"></a> [terraform\_state\_backend](#output\_terraform\_state\_backend) | Name and namespace of the etcd-snapshot / leader-lock bucket. Do NOT store Terraform state in it: nodes can write it and destroy/clean delete it. Use a separate bucket (see README: Remote Terraform state); the namespace is the same. |
| <a name="output_vault_id"></a> [vault\_id](#output\_vault\_id) | OCI Vault OCID (null if enable\_vault = false) |
<!-- END_TF_DOCS -->