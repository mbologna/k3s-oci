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
    ./example/get-kubeconfig.sh

# SSH into a cluster node via OCI Bastion (node: server1/server2/server3/worker or IP)
ssh node="worker":
    ./example/ssh-node.sh {{node}}

# Update ArgoCD gitops repo URL in all manifests after forking
update-gitops-url url:
    ./gitops/update-repo-url.sh {{url}}

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

# Run ShellCheck on all cloud-init lib scripts
shellcheck:
    shellcheck --severity=warning \
        files/lib/common.sh \
        files/lib/k3s-server.sh \
        files/lib/k3s-bootstrap.sh \
        files/lib/k3s-secrets.sh \
        files/lib/k3s-cert-manager.sh \
        files/lib/k3s-external-secrets.sh \
        files/lib/k3s-argocd.sh \
        files/lib/k3s-agent.sh

# Run YAML lint on gitops/ and .github/workflows/
yamllint:
    yamllint -d '{extends: relaxed, rules: {line-length: {max: 200}}}' gitops/ .github/workflows/

# Run tflint (Terraform linter) — requires tflint installed
tflint:
    tflint --init && tflint --recursive

# Run Trivy IaC scan for HIGH/CRITICAL findings — requires trivy installed
trivy:
    trivy config . --severity HIGH,CRITICAL --skip-dirs .terraform,example/.terraform

# Generate and inject terraform-docs into README.md — requires terraform-docs installed
docs:
    terraform-docs .

# Run all CI checks locally (fmt + validate + shellcheck + yamllint + tflint + trivy)
ci: fmt validate shellcheck yamllint tflint trivy
