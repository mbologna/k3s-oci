# Design and limits

Why the cluster has the shape it has, what it survives, where workloads run, and what it costs.

## Layout

**Public NLB** forwards HTTP/HTTPS directly to Traefik's NodePorts on both nodes. `is_preserve_source = true` preserves real client IPs at the hypervisor level. The NLB optionally exposes the Kubernetes API on port 6443, restricted to your IP.

**Internal Flex LB** provides a stable private VIP for the control-plane node. Workers join via this VIP; the optional public kubeapi listener on the NLB targets the server directly.

**Longhorn** runs on both nodes with `defaultReplicaCount=2`; each PVC is replicated across both nodes. User workloads schedule on both nodes ([Node roles](#node-roles-and-workload-placement)).

The server and worker run in different fault domains (`fault_domains` / `standalone_worker_fault_domain`). Why there are only two nodes and what a single etcd node means: see [Why this topology](#why-this-topology) and [Failure tolerance](#failure-tolerance) below.

Other choices the module makes:

- The k3s release is resolved from its channel (`update.k3s.io`) at plan time and written into the user-data, so every node of an apply installs the same version.
- The IAM dynamic group matches the instances in the cluster's compartment (tag matching breaks instance_principal for pool members), and its policy grants only narrow verbs: read instances, read the Vault secrets cloud-init needs, push logs, write objects in the cluster bucket.
- cloud-init is idempotent: every `kubectl` change is an apply, so re-provisioning a node is safe.
- Traefik is a DaemonSet with `system-cluster-critical` priority and `externalTrafficPolicy: Local`, so each node serves ingress itself and keeps the client IP ([Deploying applications](applications.md#deploying-a-web-application)).
- MySQL HeatWave (`enable_mysql`, opt-in) runs in the private subnet, and cloud-init pre-creates its credentials as the `mysql-credentials` Secret in `default`.
- With `expose_ssh = true` the NLB forwards port 22 to the nodes, restricted to `my_public_ip_cidr`, which replaces Bastion sessions for day-to-day access.

## Why this topology

OCI reduced the A1.Flex Always Free allocation in June 2026 from 4 OCPUs/24 GB to **2 OCPUs/12 GB** (max 2 instances). The result is 1 control-plane + 1 standalone worker, no etcd HA, but full use of the free allocation.

### Topology comparison

| Topology | etcd HA | Nodes for workloads | Effective RAM for workloads† | Assessment |
|---|:---:|:---:|:---:|---|
| **1 CP + 1 worker (this module)** | ❌ Single node | 2 (taints removed) | ~10 GB | **Only viable option** within 2 OCPU / 12 GB Always Free limit |
| 2 CP + 0 workers | ❌ 2-node etcd invalid | 2 | ~9 GB | 2-node etcd cannot form quorum; worse than 1 node |

†etcd + kubeapi consume ~300-500 MB RAM and ~100-200m CPU per control-plane node.

### Why not use the 2 free E2.1.Micro instances as extra workers?

Always Free also includes 2 AMD E2.1.Micro instances. They are not worth adding:

1. **1 GB RAM**: k3s agent + Longhorn DaemonSet alone consume ~700-800 MB, leaving ~200 MB for user workloads
2. **1/8 OCPU**: negligible compute; adds operational complexity for near-zero workload benefit

### Previously rejected alternatives

| Alternative | Why it was rejected |
|---|---|
| nginx stream proxy in front of Traefik | Extra latency and complexity; NLB already preserves source IPs directly |
| OCI Bastion VM (E2.1.Micro) | OCI Bastion Service provides managed SSH proxying for free with no VM, no OS to patch, and no boot volume consuming storage budget |
| Boot volumes < 50 GB | OCI hard minimum is 50 GB per shape; the default 2 × 100 GB uses the whole 200 GB free block storage allowance |
| Additional NLB for kubeapi | Only 1 NLB is Always Free; the existing NLB conditionally exposes port 6443 via `expose_kubeapi = true` |

## Failure tolerance

| Component | Tolerance | What happens on failure |
|---|---|---|
| **Worker node failure** | ⚠️ Partial | Workloads reschedule to the control plane *if their CPU/memory requests fit* in what it has left after k3s itself and etcd; the rest wait Pending until the worker returns. Longhorn (2 replicas) keeps storage up. Keep the control plane's requests well under its allocatable if you need the worker's workloads to fit there |
| **Control-plane failure** | ❌ None | Single etcd node, cluster becomes unavailable; restore from etcd snapshot |
| **HTTP/HTTPS ingress** | ✅ Worker loss | Traefik DaemonSet on control-plane keeps ingress up |
| **Kubernetes API** | ❌ CP loss | Single control-plane; ILB has no failover target |
| **PVC data (Longhorn)** | ✅ 1 node | 2 replicas across 2 nodes; 1 replica lost, 1 remains serving |
| **cert-manager** | ⚠️ Soft | Pod reschedules within minutes; TLS serving unaffected (certs live in Secrets); only new issuance/renewal is paused |
| **Planned reboots / k3s upgrades** | ⚠️ Brief | One node at a time; see [Automatic updates](updates.md#automatic-updates-and-reboots). A node left cordoned after a failed upgrade is not reported unless you enable `gitops/node-cordon-alert/` |
| **ArgoCD** | ⚠️ Soft | GitOps sync pauses until rescheduled; running workloads unaffected |
| **MySQL (if enabled)** | ❌ None | Always Free tier = single OCI-managed instance; no HA failover |

## Node roles and workload placement

Each A1.Flex instance has identical resources (1 OCPU / 6 GB RAM). The k3s role (server vs agent) affects which system processes run, not how much resource is available for workloads.

| What | control-plane-0 | worker-0 | Scheduling mechanism |
|---|:---:|:---:|---|
| **etcd** | ✅ | ❌ | k3s built-in; servers only |
| **Kubernetes API server** | ✅ | ❌ | k3s built-in; servers only |
| **Traefik** (ingress) | ✅ | ✅ | DaemonSet (1 pod per node) |
| **Longhorn** (storage daemon) | ✅ | ✅ | DaemonSet (1 pod per node) |
| **cert-manager**, **External Secrets**, **Tailscale operator** | ✅ | ✅ | Deployments: prefer the worker, run on the control plane while it is drained |
| **ArgoCD** | ✅ | ✅ | `argocd-server`: one replica per node. Controller, redis, notifications, applicationset, repo-server: prefer the worker. Dex is off (no SSO) |
| **kured** | ✅ | ✅ | DaemonSet (1 pod per node) |
| **User workloads** | ✅ | ✅ | No restrictions, schedules on both nodes |

> **Why control-plane runs user workloads:** with one worker, a tainted server would make that worker a single point of failure for every workload. k3s does not taint servers by default; cloud-init still removes any `control-plane`/`etcd` `NoSchedule` taint defensively. Keep IO-heavy batch jobs (CI runners, Renovate, image builds) off the server with a **required** `node-role.kubernetes.io/control-plane DoesNotExist` node affinity: they slow etcd's fsync on the shared boot volume. Give them `priorityClassName: worker-pinned` (`gitops/priority-classes/`) too: after a drain of the control plane its pods sit on the worker and fill its CPU requests, and the class lets a worker-pinned pod preempt them instead of waiting Pending.
>
> **Pods go back where they prefer:** nothing moves a pod once it is running, so after kured drains the worker, the pods that prefer it stay on the control plane. A nightly descheduler run (04:30 UTC, `gitops/apps/descheduler.yaml`) evicts a pod that sits off its preferred node when it fits there, and does nothing else.

### Memory budget (measured)

The control plane runs out of memory long before CPU, so the module's small controllers prefer the worker (table above). Measured on a cluster built from this module (2 nodes, ~60 pods, about 40 Argo CD Applications), November 2026:

| | Control plane | Worker |
|---|---|---|
| k3s process (`k3s.service` / `k3s-agent.service` memory, peak since boot) | 2.2 GiB (2.4; up to 2.9 right after a k3s upgrade) | 0.5–0.65 GiB (0.86) |
| `system-reserved` (kubelet) | 3 GiB, 150m CPU | 1280 MiB, 100m CPU |
| Allocatable | 2.5 GiB, 850m | 4.2 GiB, 900m |
| Pods' working set, controllers on the control plane | 1.4 GiB | 1.1 GiB |
| Pods' working set, controllers on the worker | 1.05 GiB | 2.1 GiB |
| Memory requests, controllers on the worker | 38% | 43% |
| CPU use (`kubectl top`) | ~20% | ~12% |

`system-reserved` covers the k3s process because every pod's containerd-shim is charged to its unit, which is why it is larger on the server. It was sized with the Oracle Cloud Agent, snapd and the image's idle daemons still running; Ubuntu nodes built since `remove_oci_agent` drop them, about 100 MiB less per node. With the controllers on the control plane its node had ~2.1 GiB available; after the move, ~2.4 GiB. Keep pods' memory requests at what they really use (the scheduler sees only requests), and measure before adding anything big to the control plane: `systemctl show k3s -p MemoryCurrent -p MemoryPeak`, `kubectl top nodes`, and `kubectl describe node` for allocated requests.

## Spend alert

An Always Free deployment costs nothing, so any spend means something left the free allowance (a
Pay As You Go tenancy over the 10 GB Object Storage limit, a resized shape, a leftover resource).
Set `budget_alert_email` and the module creates an OCI budget on the whole tenancy, `budget_amount`
(default 1, in the tenancy's billing currency) per month, with email alerts at 50% and 100% of actual
spend and at 100% of the month's forecast. Budgets are free and only alert; they never stop anything.
The budget lives in the root compartment, so the user running `tofu apply` needs
`manage usage-budgets in tenancy`.

## Idle reclamation

OCI reclaims Always Free instances where CPU, network, and memory stay below 20% for 7 consecutive days. The full stack (Longhorn, ArgoCD, cert-manager, kured) generates enough background activity to keep the cluster alive.

## Why not an existing tool

- [terraform-oci-oke](https://github.com/oracle-terraform-modules/terraform-oci-oke) (Oracle's module for OKE, its managed Kubernetes) builds OKE, not k3s, so it has no etcd snapshot uploads.
- It also leaves out the rest of this stack: no Longhorn with its backup target, no OCI Vault and External Secrets wiring, no Tailscale bootstrap, no Traefik behind the NLB with client IPs kept, and no rebuild that keeps data.
- [garutilorenzo/k3s-oci-cluster](https://github.com/garutilorenzo/k3s-oci-cluster) (a k3s module for OCI) has had no push since July 2025.

Checked 2026-11-23.
