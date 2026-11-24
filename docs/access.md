# Cluster access

How to reach the cluster after `tofu apply`: kubeconfig, SSH, a cluster CA that survives rebuilds, and what changes if the public NLB is recreated.

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

## Stable cluster CA across rebuilds

Every `--cluster-init` normally generates a new cluster CA, so kubeconfigs stored elsewhere
(a password manager, dotfiles) stop working after a rebuild. To keep them valid, store the CA
in OCI Vault and set `k3s_ca_vault_secret_id` (requires `enable_vault = true`):

```bash
# export the running cluster's CA (through Bastion or the NLB, like just ssh), so existing
# kubeconfigs keep working, and store it as the Vault secret <cluster_name>-k3s-ca:
CLUSTER_NAME=mycluster VAULT=true just k3s-ca-export
# it prints the line to add to terraform.tfvars:
#   k3s_ca_vault_secret_id = "<secret OCID>"
```

`scripts/k3s-ca-export.sh` also leaves the bundle in `./<cluster_name>-k3s-ca.b64` (mode 600): it
holds the CA private keys, so keep it somewhere safe or delete it. By hand, the bundle is
`sudo tar -czf - -C /var/lib/rancher/k3s/server/tls server-ca.crt server-ca.key client-ca.crt client-ca.key | base64 -w0`
on the server, and the Vault secret's value is that base64 text.

The first server extracts the four files before `--cluster-init`. k3s reuses existing CA files
instead of generating them, so the cluster keeps the same CA. If the secret is set but cannot
be fetched or extracted, cloud-init aborts instead of minting a new CA. Admin client certs
signed by `client-ca` (with `O=system:masters`) then survive rebuilds. The secret is created
outside the module, so `tofu destroy` never deletes it.

Setting it on an existing cluster takes effect at the next full rebuild: instance configurations
ignore `user_data` changes, so a server the pool relaunches meanwhile still boots without it.

## NLB IP stability

The public NLB is never replaced by an ordinary `tofu apply`, so its IP is stable across applies.
It has `prevent_destroy = false` (so `tofu destroy` works for full rebuilds); if the NLB is **ever recreated** (destroy + apply, or `tofu state rm` + re-apply):

- All `sslip.io` hostnames change (e.g. `argocd.<old-ip>.sslip.io` → `argocd.<new-ip>.sslip.io`)
- Let's Encrypt certificates are invalid for the new hostnames and must be reissued
- With a custom domain + `enable_external_dns = true`, ExternalDNS updates DNS automatically and cert-manager auto-renews

**If using sslip.io defaults**, run `tofu apply` again after NLB recreation: `local.argocd_hostname` recomputes automatically from the new IP, cloud-init re-creates the Ingresses and certificates, and cert-manager reissues via Let's Encrypt.
