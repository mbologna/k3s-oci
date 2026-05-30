# Common operations for k3s-oci.
# Install just: https://github.com/casey/just
# Usage: just <recipe>  (e.g. just apply, just kubeconfig, just ssh worker)

default:
    just --list

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

# Fetch kubeconfig via OCI Bastion (requires example/get-kubeconfig.sh)
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
    tofu validate && cd example && tofu validate

# Show all Terraform outputs
outputs:
    cd example && tofu output

# Show kubeconfig hint
kubeconfig-hint:
    cd example && tofu output kubeconfig_hint
