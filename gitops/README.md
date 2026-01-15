# GitOps — App of Apps

This directory contains ArgoCD `Application` manifests managed via the [App of Apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern).

## Structure

```
gitops/
├── apps/                           # ArgoCD Application manifests (App of Apps root)
│   ├── app-of-apps.yaml            # Root Application — bootstrapped by cloud-init
│   ├── argocd-config.yaml          # ArgoCD supplementary config (rate-limit middleware)
│   ├── kube-prometheus-stack.yaml  # Prometheus + Grafana + Alertmanager (Helm)
│   ├── monitoring-extras.yaml      # PrometheusRules, ServiceMonitor, Grafana IngressRoute
│   ├── network-policies.yaml       # NetworkPolicies for all namespaces
│   ├── pdbs.yaml                   # PodDisruptionBudgets for core components
│   └── traefik-config.yaml         # Traefik TLSOptions and redirect Middleware
├── argocd/                         # ArgoCD supplementary config
│   └── rate-limit.yaml             # Traefik RateLimit Middleware for ArgoCD UI
├── cert-manager/                   # ClusterIssuer templates (see adoption notes)
│   ├── cluster-issuers.yaml        # Template — update email before using
│   └── application-template.yaml  # Copy to apps/ after updating email
├── longhorn/                       # Longhorn supplementary config
│   ├── ingress.yaml                # BasicAuth IngressRoute template
│   └── backup-target.yaml         # OCI Object Storage backup target template (see file for setup)
├── monitoring/                     # Supplementary monitoring resources
│   ├── alertmanager-config.yaml    # AlertmanagerConfig template (Slack/email/webhook)
│   ├── grafana-ingress.yaml        # Traefik IngressRoute for Grafana (update hostname)
│   ├── longhorn-servicemonitor.yaml # ServiceMonitor for Longhorn metrics scraping
│   ├── prometheus-rules.yaml       # Disk + Longhorn alert rules
│   └── README.md                   # Grafana access, dashboards, alerting how-to
├── network-policies/               # NetworkPolicies (default-deny + allow rules)
│   ├── default-deny.yaml           # default namespace
│   ├── argocd.yaml                 # argocd namespace
│   ├── cert-manager.yaml           # cert-manager namespace
│   ├── longhorn-system.yaml        # longhorn-system namespace
│   └── monitoring.yaml             # monitoring namespace
├── pdbs/                           # PodDisruptionBudgets
│   └── pod-disruption-budgets.yaml # ArgoCD, cert-manager PDBs
├── traefik/                        # Traefik configuration
│   ├── redirect.yaml               # HTTP→HTTPS RedirectScheme middleware + catch-all route
│   └── tlsoptions.yaml             # TLSOption enforcing TLS 1.2+ and strong ciphers
├── update-repo-url.sh              # Helper: update repoURL after forking (see below)
└── README.md
```

## Forking this repo

All `Application` manifests in `gitops/apps/` contain a hardcoded `repoURL` pointing to
`https://github.com/mbologna/k3s-oci.git`. If you fork the repo, run the helper script
**once** after cloning to update all references:

```bash
bash gitops/update-repo-url.sh https://github.com/your-org/your-fork.git
git add gitops/apps/ && git commit -m "chore: update gitops repoURL to fork"
git push
```

Then set `gitops_repo_url = "https://github.com/your-org/your-fork.git"` in your
`terraform.tfvars` so cloud-init bootstraps the App of Apps with the correct URL.

## Bootstrap

The App of Apps is bootstrapped automatically by cloud-init. After provisioning,
ArgoCD self-manages everything in `gitops/apps/`.

To manually re-apply:
```bash
kubectl apply -n argocd -f gitops/apps/app-of-apps.yaml
```

## Adding a new application

1. Create a new `Application` manifest in `gitops/apps/`.
2. Commit and push. ArgoCD will detect it via the App of Apps and apply it automatically.

## ArgoCD Image Updater

Image Updater is installed alongside ArgoCD. To enable automatic image updates for a deployment:

```yaml
# Add these annotations to your ArgoCD Application manifest in gitops/apps/
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
  annotations:
    # Track the latest semver tag for myrepo/myapp
    argocd-image-updater.argoproj.io/image-list: myapp=ghcr.io/myorg/myapp:~1.0
    argocd-image-updater.argoproj.io/myapp.update-strategy: semver
    # Write back to git (recommended for GitOps)
    argocd-image-updater.argoproj.io/write-back-method: git
    argocd-image-updater.argoproj.io/git-branch: main
```

For a Helm-based Application, also add:
```yaml
    argocd-image-updater.argoproj.io/myapp.helm.image-name: image.repository
    argocd-image-updater.argoproj.io/myapp.helm.image-tag: image.tag
```

Supported update strategies: `semver` (recommended), `latest`, `digest`, `name`.

See [Image Updater docs](https://argocd-image-updater.readthedocs.io/) for full reference.

## TLS options

All IngressRoutes should reference the `tls-modern` TLSOption from `gitops/traefik/` to enforce TLS 1.2+:

```yaml
spec:
  tls:
    secretName: my-tls-secret
    options:
      name: tls-modern
      namespace: traefik
```

