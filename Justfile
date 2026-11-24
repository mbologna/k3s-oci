# Common operations for k3s-oci.
# Install just: https://github.com/casey/just
# Usage: just <recipe>  (e.g. just apply, just kubeconfig, just ssh worker)

default:
    just --list

# OCI Go SDK has a TLS/HTTP2 bug — GODEBUG=http2client=0 is required for all tofu operations.
export GODEBUG := "http2client=0"

# Initialize Terraform/OpenTofu providers
init:
    cd example && tofu init

# Preview infrastructure changes
plan:
    cd example && tofu plan

# Apply infrastructure changes
apply:
    cd example && tofu apply

# Destroy all infrastructure (requires confirmation)
destroy:
    cd example && tofu destroy

# Full deploy: init → apply → kubeconfig (idempotent)
deploy:
    just init
    just apply
    just kubeconfig

# Fetch kubeconfig via OCI Bastion or direct NLB SSH (auto-detected)
kubeconfig:
    cd example && ./get-kubeconfig.sh

# SSH into a cluster node via OCI Bastion or the NLB (node: server/worker or a private IP)
ssh node="worker":
    cd example && ./ssh-node.sh {{node}}

# Update ArgoCD gitops repo URL in all manifests after forking
update-gitops-url url:
    ./gitops/update-repo-url.sh {{url}}

# Delete orphaned OCI networking resources after a failed/partial destroy
# Requires COMPARTMENT_OCID env var; CLUSTER_NAME defaults to k3s-oci
clean-oci-resources:
    ./scripts/clean-oci-resources.sh

# Destroy the cluster but keep the Vault and buckets (etcd snapshots, Longhorn backups)
# and re-import them into state, ready for `just apply`. Requires COMPARTMENT_OCID;
# CLUSTER_NAME defaults to k3s-oci. Resume a failed import with IMPORT_ONLY=true.
teardown-keep-data:
    ./scripts/teardown-keep-data.sh

# Fresh etcd snapshot + Longhorn backup of every volume, e.g. right before a teardown
# (PRE_BACKUP=true just teardown-keep-data runs it too). Needs kubectl access.
pre-teardown-backup:
    ./scripts/pre-teardown-backup.sh

# After a rebuild: restore every Longhorn PVC from its newest backup. Needs kubectl access.
longhorn-restore:
    ./scripts/longhorn-restore.sh

# Export the cluster CA (for k3s_ca_vault_secret_id); VAULT=true also stores it in OCI Vault
k3s-ca-export:
    ./scripts/k3s-ca-export.sh

# Wire Longhorn backups to OCI Object Storage (interactive).
# Use when user_ocid is not set in tfvars — creates Customer Secret Key, K8s Secret,
# and applies the Longhorn BackupTarget. Requires kubectl + oci CLI configured.
# Optional: CLUSTER_NAME env var (defaults to k3s-oci).
setup-longhorn-backup:
    ./scripts/setup-longhorn-backup.sh

# Format all Terraform files
fmt:
    tofu fmt -recursive .

# Validate Terraform configuration (root + example/)
validate:
    tofu init -backend=false -reconfigure && tofu validate
    cd example && tofu init -backend=false -reconfigure && tofu validate

# Show all Terraform outputs
outputs:
    cd example && tofu output

# Show kubeconfig hint
kubeconfig-hint:
    cd example && tofu output kubeconfig_hint

# Generate docs (alias)
readme:
    just docs

# Run ShellCheck on all cloud-init lib scripts and helper scripts (same list as ci.yml)
shellcheck:
    shellcheck --severity=warning \
        files/lib/bootstrap-ubuntu.sh \
        files/lib/bootstrap-opensuse.sh \
        files/lib/bootstrap-opensuse-immutable.sh \
        files/lib/two-phase.sh \
        files/lib/two-phase-done.sh \
        files/lib/common.sh \
        files/lib/k3s-server.sh \
        files/lib/k3s-bootstrap.sh \
        files/lib/k3s-secrets.sh \
        files/lib/k3s-cert-manager.sh \
        files/lib/k3s-external-secrets.sh \
        files/lib/k3s-argocd.sh \
        files/lib/k3s-agent.sh \
        scripts/clean-oci-resources.sh \
        scripts/teardown-keep-data.sh \
        scripts/import-opensuse-aarch64.sh \
        scripts/setup-longhorn-backup.sh \
        scripts/k3s-ca-export.sh \
        scripts/pre-teardown-backup.sh \
        scripts/longhorn-restore.sh \
        scripts/validate-gitops.sh \
        scripts/check-bootstrap-chart-versions.sh \
        gitops/update-repo-url.sh \
        example/get-kubeconfig.sh \
        example/ssh-node.sh

# Run YAML lint on gitops/ and .github/workflows/
yamllint:
    yamllint -d '{extends: relaxed, rules: {line-length: {max: 200}}}' gitops/ .github/workflows/

# Validate gitops/ manifests with kubeconform and check that the bootstrap chart
# versions in vars.tf match the gitops targetRevisions — requires kubeconform, kustomize
gitops-lint:
    scripts/check-bootstrap-chart-versions.sh
    scripts/validate-gitops.sh

# Run tflint (Terraform linter) — requires tflint installed
tflint:
    tflint --init && tflint --recursive

# Run Trivy IaC scan for HIGH/CRITICAL findings — requires trivy installed
trivy:
    trivy config . --severity HIGH,CRITICAL --skip-dirs .terraform,example/.terraform

# Generate and inject terraform-docs into README.md — requires terraform-docs installed
docs:
    terraform-docs .

# Run all CI checks locally (fmt + validate + shellcheck + yamllint + gitops-lint + tflint + trivy)
ci: fmt validate shellcheck yamllint gitops-lint tflint trivy
