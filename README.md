# k3s-oci

A Terraform/OpenTofu module for a highly available [k3s](https://k3s.io) cluster on Oracle Cloud's
free allowance, on an image-based OS: openSUSE Leap Immutable (default), Fedora CoreOS or Flatcar
Container Linux. Argo CD then runs the cluster from a GitOps repository; this one ships a working
default (Traefik, Longhorn, cert-manager, kured, system-upgrade-controller, NetworkPolicies).

Its sibling [talos-oci](https://github.com/mbologna/talos-oci) builds the same on Talos Linux.

## What it builds

| | Default | Free allowance used |
|---|---|---|
| Nodes | 2 k3s servers, both running workloads: 2 OCPU / 12 GB each (A1.Flex, arm64) | 4 OCPU / 24 GB of A1 (Pay As You Go tenancies; 2 / 12 on never-upgraded ones) |
| Datastore | MySQL HeatWave (MySQL.Free) through kine: etcd's fsync load off the boot volumes, any server replaceable on its own. `datastore = "etcd"` for embedded etcd on 1 or 3 servers | The free MySQL HeatWave system |
| Storage | 100 GB boot volumes, Longhorn with 2 replicas | 200 GB block storage |
| Ingress | Public network load balancer → Traefik's NodePorts (30080/30443) on every node, client IP preserved | The free NLB |
| API | Internal load balancer for the Kubernetes API (6443), reached through OCI Bastion; Terraform outputs an admin kubeconfig | The free 10 Mbps flexible LB, Bastion |
| Backups | A versioned bucket for etcd snapshots and Longhorn backups; weekly boot-volume backups; Oracle's daily database backups | Object Storage, 2 of 5 volume backups |
| Network | Private nodes behind NAT; Oracle services through a Service Gateway | NAT and service gateways |
| Alerts (opt-in) | OCI Monitoring alarms (instance down, unhealthy NLB backends) and an APM synthetic uptime check | Monitoring, Notifications, APM free tier |

Nothing administrative is public. The nodes install k3s from their own boot script; the first
installs Argo CD, which syncs the App of Apps from `gitops_repo_url`.

## Quick start

Requirements: OpenTofu ≥ 1.9 (or Terraform), the OCI CLI, `kubectl`, `qemu-img`, `curl`,
`python3`, `ssh` (and `xz` for Fedora CoreOS).

```bash
cd example
cp terraform.tfvars.example terraform.tfvars          # tenancy, compartment, AD, region, os_family
cp backend_override.tf.example backend_override.tf    # optional: remote state in OCI
cd ..
OS_FAMILY=opensuse scripts/deploy.sh
```

`deploy.sh` imports the OS image (and deletes it afterwards: custom images cost Object Storage),
applies, writes the kubeconfig output to `~/.kube/k3s-oci-<cluster>` and waits for the servers
through `scripts/tunnel.sh`. To run your own applications, fork the repository and point Argo CD
at it ([docs/operations.md](docs/operations.md#your-own-applications)).

## Limits

- The datastore is one MySQL.Free system: no HA (the free shape has none), restored from Oracle's
  daily backup. A database outage stops the Kubernetes API; running pods keep running.
- The node configuration holds the k3s token, the cluster CA keys and the database password; it
  is in instance metadata (or behind a pre-authenticated request). See [SECURITY.md](SECURITY.md).
- Version 3 has been validated by rendering and CI only, not on a live tenancy yet (the author's
  free allowance runs talos-oci). Reports welcome.

## Documentation

- [docs/design.md](docs/design.md): topology, OS choices, components and the alternatives.
- [docs/operations.md](docs/operations.md): deploying, access, upgrades, backups, replacing a
  node, your own applications.
- [gitops/README.md](gitops/README.md): the default applications.

Version 3 is a rewrite: there is no upgrade path from 2.x (`?ref=v2.5.0` keeps working).
