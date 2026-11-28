#!/usr/bin/env bash
# node-vars.sh.tpl -- the Terraform-rendered header of the node script (nodes.tf).
# The only file in files/ with Terraform interpolation: files/lib/*.sh are plain
# bash, appended in order after it.

set -euo pipefail
# Appended, not truncated: on image-based OSes the script runs again after the
# first-boot reboot (two-phase.sh), and both runs belong in one log.
exec > >(tee -a /var/log/k3s-oci-bootstrap.log | logger -t k3s-oci-bootstrap) 2>&1
echo "==> k3s-oci node bootstrap starting at $(date -u)"

export CLUSTER_NAME="${cluster_name}"
export NODE_NAME="${node_name}"
export FIRST_NODE="${first_node ? "true" : "false"}"
export OS_FAMILY="${os_family}"
export OS_USER="${os_user}"
export SSH_PUBLIC_KEY="${ssh_public_key}"
export K3S_CHANNEL="${k3s_channel}"
export K3S_VERSION="${k3s_version}"
export ARGOCD_CHART_VERSION="${argocd_chart_version}"
export FCOS_STREAM="${fcos_stream}"

# The k3s config drop-in, the bootstrap manifests and the cluster CAs, rendered by
# Terraform. The config holds the cluster token and the database password, the
# CA files their keys (SECURITY.md).
K3S_CONFIG_B64="${k3s_config_b64}"
MANIFESTS_B64="${manifests_b64}"
CA_FILES="${ca_files}"
