# ── Fetch kubeconfig via OCI Bastion Service ─────────────────────────────
# Run from the example/ directory (requires oci CLI, tofu, jq, nc, ssh):
#   ./get-kubeconfig.sh
#
# Or manually — port-forwarding session (no Bastion plugin required):
#   oci bastion session create-port-forwarding \
#     --bastion-id ${bastion_id} \
#     --ssh-public-key-file ~/.ssh/id_ed25519.pub \
#     --target-private-ip ${server_ip} \
#     --target-port 22 \
#     --session-ttl 1800
#   # Open tunnel (replace SESSION and REGION):
#   ssh -N -L 22222:${server_ip}:22 \
#       -p 22 ocid1.bastionsession...@host.bastion.<region>.oci.oraclecloud.com &
#   # Fetch kubeconfig through tunnel:
#   ssh -p 22222 ${os_user}@localhost "sudo cat /etc/rancher/k3s/k3s.yaml" \
#     | sed 's|127.0.0.1:6443|${public_nlb_ip}:${kube_api_port}|'
#
# Tip: add  expose_ssh = true  to terraform.tfvars for direct SSH without Bastion sessions.
# See the ssh_command output after tofu apply.
