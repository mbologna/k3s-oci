# GitOps — App of Apps

This directory contains ArgoCD `Application` manifests managed via the [App of Apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern).

## Structure

```
gitops/
├── apps/
│   └── app-of-apps.yaml       # Root Application — add child Applications here
├── network-policies/
│   └── default-deny.yaml      # Default-deny for the default namespace
└── README.md
```

## Bootstrap

After the cluster is up, register the root Application:

```bash
kubectl apply -n argocd -f gitops/apps/app-of-apps.yaml
```

ArgoCD will then continuously reconcile everything under `gitops/apps/` and sync it to the cluster.

## Adding a new application

1. Create a new `Application` manifest in `gitops/apps/`.
2. Commit and push. ArgoCD will detect it via the App of Apps and apply it automatically.
