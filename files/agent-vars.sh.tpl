#!/usr/bin/env bash
# agent-vars.sh.tpl — Terraform-rendered header for k3s agent cloud-init.
# This is the ONLY file in files/ with Terraform interpolation — all other
# files/lib/*.sh are pure bash with no escaping needed.
# Concatenated by data.tf: join("\n", [templatefile(this), file(lib/common.sh), ...])

set -euo pipefail
exec > >(tee /var/log/k3s-cloud-init.log | logger -t k3s-cloud-init) 2>&1

echo "==> k3s agent cloud-init starting at $(date -u)"

export K3S_VERSION="${k3s_version}"
export K3S_SUBNET="${k3s_subnet}"
export K3S_URL="${k3s_url}"
export K3S_TOKEN_PLAIN="${k3s_token}"
export VAULT_SECRET_ID_K3S_TOKEN="${vault_secret_id_k3s_token}"
