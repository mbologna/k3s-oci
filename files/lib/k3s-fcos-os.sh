#!/usr/bin/env bash
# lib/k3s-fcos-os.sh -- appended after k3s-server.sh for os_family = "fcos" only
# (data.tf). Pure bash -- no Terraform interpolation. The first server adds the
# fcos-os upgrade Plan as an Argo CD app (gitops/optional/fcos-os.yaml,
# gitops/fcos-os/): the nodes' only source of OS updates, as the Machine Config
# Operator is on OpenShift.
# shellcheck disable=SC2154

if [[ "${IS_FIRST_SERVER:-false}" == "true" ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  if [[ -n "${GITOPS_OPTIONAL_PATH:-}" ]]; then
    create_optional_app "fcos-os" "fcos-os.yaml" \
      || echo "WARNING: fcos-os app not created; nodes get no OS updates until it exists (gitops/optional/fcos-os.yaml)."
  else
    echo "WARNING: gitops_optional_path is empty, fcos-os not added; nodes get no OS updates until you deploy gitops/fcos-os/."
  fi
fi
