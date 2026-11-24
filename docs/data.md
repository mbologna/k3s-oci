# State, secrets, backups and rebuilds

Where Terraform state, cluster secrets, etcd snapshots and volume backups live, and how to rebuild the cluster without losing them.

## Remote Terraform state (OCI Object Storage)

`enable_object_storage_state = true` (the default) creates the versioned `<cluster_name>-terraform-state`
bucket. **It holds etcd snapshots and the leader lock, do not store your Terraform state in it:**

- The nodes have `manage objects` on that bucket, and the state contains every cluster secret
  (k3s token, Longhorn UI password, OAuth secrets, …). A compromised node could read it.
- `scripts/clean-oci-resources.sh` and `tofu destroy` delete the bucket together with the cluster.

Keep the state in a separate bucket, created outside this module, that the nodes have no IAM grant on:

```bash
oci os bucket create -c <compartment_ocid> --name <cluster_name>-tofu-state \
  --versioning Enabled --public-access-type NoPublicAccess
```

Then point the S3 backend at it from a gitignored `backend_override.tf` next to your module call
(`*_override.tf` is already in this repo's `.gitignore`); `example/backend_override.tf.example` is a
copy to start from:

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
> only lives on your laptop can belong to your own user; a key stored *inside* the cluster must belong
> to a service user limited to one bucket, which [Longhorn backups](#longhorn-backups) can create for you.
> New keys take about 5 minutes to work on the S3 endpoint.

## OCI Vault secrets

With `enable_vault = true` every cluster secret below lives in the Vault and nodes fetch it
at boot (instance_principal); with `enable_vault = false` it is passed in user-data instead.
The nodes' IAM policy covers only these boot secrets (plus `k3s_ca_vault_secret_id`), unless an
instance_principal External Secrets store needs the whole compartment (see `external_secrets_instance_principal`;
`create_external_secrets_user = true` avoids that with a service user that reads only this vault).

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
| `<cluster>-external-secrets-api-key` | `create_external_secrets_user = true` |

`k3s_ca_vault_secret_id` points at a secret you create yourself (not module-managed); see
[Stable cluster CA across rebuilds](access.md#stable-cluster-ca-across-rebuilds).

## etcd snapshots

With `enable_etcd_snapshots = true` (the default; it needs `enable_object_storage_state = true`), every
server takes an etcd snapshot at the hours in `etcd_snapshot_upload_hours` (default every 6 hours, UTC)
and uploads it to `etcd-snapshots/<cluster>/<hostname>/` in the `<cluster_name>-terraform-state` bucket,
with instance_principal auth and no S3 keys. Pruning keeps the newest `etcd_snapshot_retention` snapshots
(default 5) across the whole cluster prefix. Servers start with `--secrets-encryption`, so a restore needs
the same cluster token. These snapshots are the recovery path when the single etcd node is lost: a new
server that finds them logs the `k3s server --cluster-reset` restore steps (see
[After a rebuild that kept the buckets](#after-a-rebuild-that-kept-the-buckets)).

## Longhorn backups

`enable_longhorn_backup = true` (the default) creates the `<cluster_name>-longhorn-backup` bucket.
Set `create_longhorn_backup_user = true` to wire backups end to end:

- The module creates an IAM user, a group and a policy, all named `<cluster_name>-longhorn-backup`. The policy
  allows only `read buckets` and `manage objects` on the backup bucket. The user can use Customer Secret
  Keys and nothing else.
- Terraform creates the user's Customer Secret Key. With `enable_vault = true` the secret half is
  stored in Vault as `<cluster_name>-longhorn-backup-secret-key` and fetched at boot, so it is never in user-data.
- Cloud-init creates `longhorn-backup-secret` and points the Longhorn `BackupTarget` at the bucket. It also
  applies the `daily-backup` RecurringJob to every volume in the `default` group: cron `longhorn_backup_schedule`,
  default `30 0 * * *` UTC; keeps `longhorn_backup_retain` backups, default 7.
  There is no snapshot-cleanup job: Longhorn removes system-generated snapshots and each backup's snapshot
  itself. Clusters built by earlier module versions have a `weekly-snapshot-cleanup` job that fails every week on detached
  volumes; delete it with `kubectl -n longhorn-system delete recurringjob weekly-snapshot-cleanup`.

Creating IAM users requires tenancy-level IAM permissions. Without them, keep `create_longhorn_backup_user = false`
and follow the `longhorn_backup_setup` output (or `just setup-longhorn-backup`).
`retain` is the only cleanup: do not add an age-based lifecycle rule on `backupstore/`. Expiring blocks
underneath Longhorn corrupts the incremental chain. Backups of deleted volumes are never pruned automatically.
Delete them in the Longhorn UI.

Nothing reports a backup that stopped running unless you enable `gitops/backup-monitor/`: a daily
CronJob that alerts through an [Apprise API](https://github.com/caronc/apprise-api) server when the
BackupTarget is unavailable, a volume has no backup in 36 hours, or the newest etcd snapshot upload is
older than 13 hours. Setup steps are in its `application-template.yaml`.

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
> # IMPORT_ONLY=true resumes after a failed re-import;
> # PRE_BACKUP=true first takes a fresh etcd snapshot and Longhorn backups (just pre-teardown-backup)
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
- **Longhorn backups** are not pruned by the new cluster. Once Argo CD has synced the apps,
  `just longhorn-restore` restores every Longhorn PVC from its newest backup (it skips volumes
  newer than their backup, so it never rolls a live volume back) and rebinds the PVC; pods using
  it restart. By hand: the Longhorn UI (**Backup → select → Restore**), or a `Volume` with `spec.fromBackup` set.
