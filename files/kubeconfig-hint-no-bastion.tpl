# ── No bastion configured ────────────────────────────────────────────────
# Nodes are in a private subnet and cannot be reached directly.
# Pick one option:
#
# Option A — OCI serial console (no infra change, one-time):
#   OCI console connections require an RSA key (ed25519 is not supported).
#   This one-liner creates the connection and opens the shell immediately:
#   ssh -o ControlPath=none $(oci compute instance-console-connection create \
#       --instance-id ${server_ocid} \
#       --ssh-public-key-file ~/.ssh/id_rsa.pub \
#       --query 'data."connection-string"' --raw-output)
#   # Then: sudo cat /etc/rancher/k3s/k3s.yaml
#
# Options B & C — both require a tofu apply:
#
# Option B — Enable OCI Bastion Service (managed, Always Free, no storage):
#   enable_bastion = true by default. If disabled, add it back to terraform.tfvars, then run tofu apply.
#   Then re-run: tofu output kubeconfig_hint
#
# Option C — Expose kubeapi via public NLB (restricted to ${my_public_ip_cidr}):
#   Add  expose_kubeapi = true  to terraform.tfvars, then run tofu apply.
#   Use Option A or B once to fetch the kubeconfig, then update the server URL:
#   sed -i '' 's|127.0.0.1:6443|${public_nlb_ip}:${kube_api_port}|' ~/.kube/k3s-oci.yaml
