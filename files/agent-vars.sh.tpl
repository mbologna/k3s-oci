#!/usr/bin/env bash
# agent-vars.sh.tpl -- Terraform-rendered header for k3s agent cloud-init.
# This is the ONLY file in files/ with Terraform interpolation -- all other
# files/lib/*.sh are pure bash with no escaping needed.
# Concatenated by data.tf: join("\n", [templatefile(this), file(lib/common.sh), ...])

set -euo pipefail
exec > >(tee /var/log/k3s-cloud-init.log | logger -t k3s-cloud-init) 2>&1

echo "==> k3s agent cloud-init starting at $(date -u)"

export TRACE="${trace_enabled ? "true" : "false"}"
[[ "$${TRACE}" == "true" ]] && set -x

export K3S_VERSION="${k3s_version}"
export K3S_SUBNET="${k3s_subnet}"
export K3S_URL="${k3s_url}"
export KUBE_API_PORT="${kube_api_port}"
export K3S_TOKEN_PLAIN="${k3s_token}"
export VAULT_SECRET_ID_K3S_TOKEN="${vault_secret_id_k3s_token}"

# -- Shared SSH host key (base64-encoded to survive multi-line export) ----------
export SSH_HOST_KEY_PRIVATE_B64="${ssh_host_key_private_b64}"
export SSH_HOST_KEY_PUBLIC="${ssh_host_key_public}"

# -- OS family and default SSH user --------------------------------------------
export OS_FAMILY="${os_family}"
export OS_USER="${os_user}"
# SSH_PUBLIC_KEY is used by bootstrap-opensuse.sh to inject the key directly,
# because openSUSE cloud-init does not read OCI metadata ssh_authorized_keys.
export SSH_PUBLIC_KEY="${ssh_public_key}"
