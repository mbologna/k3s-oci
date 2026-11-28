# Operations

## Deploy

```bash
OS_FAMILY=opensuse TF_DIR=example scripts/deploy.sh
```

1. `import-image.sh` downloads the OS image (openSUSE Leap Immutable Base qcow2, Fedora CoreOS's
   oraclecloud build of `FCOS_STREAM`, or Flatcar's oraclecloud image of `FLATCAR_CHANNEL`),
   checks it against its published checksum, imports it with UEFI_64 firmware and A1.Flex
   compatibility, and prints the image OCID. `deploy.sh` records it in `k3s-image.auto.tfvars`.
2. `tofu apply` creates the network, load balancers, database, Bastion, bucket and nodes.
3. Once every node runs, the custom image is deleted.
4. The nodes bootstrap on their own (`/var/log/k3s-oci-bootstrap.log` on each). On openSUSE and
   Fedora CoreOS that includes a reboot; expect 10-20 minutes.
5. `deploy.sh` writes the kubeconfig output, opens the tunnel and waits for the servers.

## Access

```bash
scripts/tunnel.sh up                      # localhost:6443 through Bastion
export KUBECONFIG=~/.kube/k3s-oci-<cluster>
kubectl get nodes
scripts/tunnel.sh ssh server-0            # break-glass shell (needs ssh_public_key)
scripts/tunnel.sh down
```

Sessions last up to three hours (`SESSION_TTL`). For day-to-day kubectl without Bastion, run the
Tailscale operator (`gitops/tailscale-operator/`) with `apiServerProxyConfig`. The admin
certificate lasts a year; any apply in its last 30 days renews it (`tofu output -raw kubeconfig`).

## Upgrades

- **k3s:** the system-upgrade-controller Plan in `gitops/system-upgrade/plans.yaml` follows the
  stable channel in a 23:00-23:59 UTC window, one node at a time (pin a `version:` to let Renovate
  drive it). Flatcar nodes are excluded: systemd-sysupdate patches their k3s sysext within the
  minor, and a new minor is a new `k3s_version` plus node replacement.
- **OS, openSUSE:** daily security patches and Tuesday-Thursday routine patches into a new
  snapshot; kured reboots (02:15-04:15 UTC, security on any night).
- **OS, Flatcar:** update_engine downloads; kured reboots.
- **OS, Fedora CoreOS:** the `fcos-os` Plan (`gitops/fcos-os/`) rolls the release pinned there
  out, drained, one node at a time, Tuesday-Thursday. Keep `fcos_os_version` equal to it.
- **Machine changes** (the module's node script): new nodes only; the instances ignore user_data
  changes. Replace nodes one at a time.

## Backups

- **Cluster state, mysql:** Oracle's daily automatic backup (kept one day). For longer history,
  run a `mysqldump` CronJob to the bucket (`tofu output mysql_endpoint`, `mysql_password`).
- **Cluster state, etcd:** k3s snapshots every 12 hours; with `etcd_s3_access_key` they go to
  the bucket's `etcd/` prefix. Restore: `k3s server --cluster-reset --cluster-reset-restore-path`.
- **Longhorn:** a BackupTarget pointing at `s3://<cluster>-backups@<region>/longhorn/`
  (`gitops/longhorn/backup-target.yaml`), with `pollInterval` at a day: the 5-minute default
  exceeds the free 50,000 requests a month.
- **Boot volumes:** weekly, kept a week.

Restoring needs the Terraform state too: it holds the k3s token (which decrypts the datastore's
Secrets) and the cluster CAs.

## Replace a node

```bash
OS_FAMILY=opensuse scripts/import-image.sh   # prints the image OCID
tofu -chdir=example apply -var image_id=<ocid> -replace='module.k3s_oci.oci_core_instance.node["server-1"]'
oci compute image delete --image-id <ocid> --force
```

With `datastore = "mysql"` the new server joins on its own. With etcd, remove the old member
first (`kubectl delete node`, then `k3s etcd-snapshot` and the etcd member list on a survivor).

## Your own applications

1. Fork the repository and run `gitops/update-repo-url.sh https://github.com/you/k3s-oci.git`.
2. Set `gitops_repo_url` to your fork (`gitops_https_username` / `gitops_https_token` for a
   private one).
3. Add Argo CD Applications to `gitops/apps/`.

## Tear down

`tofu destroy` removes everything the module created. The bucket must be empty first (it is
versioned: delete every object version).
