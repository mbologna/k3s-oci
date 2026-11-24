# GitOps — App of Apps

This directory contains ArgoCD `Application` manifests managed via the [App of Apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern).

## Structure

```
gitops/
├── apps/                             # ArgoCD Application manifests (App of Apps root)
│   ├── app-of-apps.yaml              # Root Application — bootstrapped by cloud-init
│   ├── argocd.yaml                   # ArgoCD Helm release
│   ├── argocd-config.yaml            # ArgoCD supplementary config (rate-limit Middleware)
│   ├── cert-manager.yaml             # cert-manager Helm release
│   ├── coredns.yaml                  # CoreDNS replica count (gitops/coredns/)
│   ├── descheduler.yaml              # Nightly descheduler: pods back to their preferred node
│   ├── kured.yaml                    # kured Helm release
│   ├── longhorn.yaml                 # Longhorn Helm release
│   ├── network-policies.yaml         # NetworkPolicies for all namespaces
│   ├── priority-classes.yaml         # PriorityClasses (gitops/priority-classes/)
│   ├── system-upgrade-controller.yaml # system-upgrade-controller for k3s upgrades
│   └── traefik.yaml                  # Traefik Helm release: ingress, HTTP→HTTPS redirect, TLS options
├── argocd/                           # ArgoCD supplementary config
│   └── rate-limit.yaml               # Traefik rateLimit Middleware (100 req/s/IP for ArgoCD UI)
├── coredns/                          # HPA pinning k3s's CoreDNS at 2 replicas, one per node
│   └── hpa.yaml
├── cert-manager/                     # ClusterIssuer templates (see adoption notes)
│   ├── cluster-issuers.yaml          # Template — update email before using
│   └── application-template.yaml    # Copy to apps/cert-manager-issuers.yaml after updating email
├── optional/                         # Opt-in Applications, outside the App of Apps scope
│   ├── argocd-image-updater.yaml     # Argo CD Image Updater; copy to apps/ to install
│   ├── external-dns.yaml             # Reference only: cloud-init creates the real app (runtime filters)
│   └── external-secrets.yaml         # ESO Helm release; wrapped by cloud-init when enable_external_secrets = true
├── external-secrets/                 # External Secrets templates
│   ├── cluster-secret-store-template.yaml  # ClusterSecretStore backed by OCI Vault
│   └── example-external-secrets.yaml       # Example ExternalSecret CRs
├── longhorn/                         # Longhorn supplementary config
│   ├── ingress.yaml                  # Ingress + basicAuth Middleware template
│   ├── backup-target.yaml            # BackupTarget CR setup steps + weekly RecurringJob template
│   └── taint-toleration.yaml         # Worker node NoSchedule taint Setting template (uncomment + set taint key)
├── network-policies/                 # NetworkPolicies (default-deny + allow rules per namespace)
│   ├── namespaces.yaml               # external-dns / external-secrets / traefik namespaces (so their policies apply)
│   ├── default-deny.yaml             # default namespace
│   ├── argocd.yaml                   # argocd namespace (includes port 22 SSH egress for git clone)
│   ├── cert-manager.yaml             # cert-manager namespace (includes port 80 egress for HTTP-01)
│   ├── external-dns.yaml             # external-dns namespace (optional feature)
│   ├── external-secrets.yaml         # external-secrets namespace (optional feature)
│   ├── kube-system.yaml              # kube-system namespace
│   ├── longhorn-system.yaml          # longhorn-system namespace
│   ├── system-upgrade.yaml           # system-upgrade namespace
│   └── traefik.yaml                  # traefik namespace (NodePort ingress + backend egress)
├── priority-classes/                 # PriorityClasses: platform-critical, alerting, worker-pinned
├── node-cordon-alert/                # Opt-in: webhook alert when a node stays cordoned (copy application-template.yaml to apps/)
├── backup-monitor/                   # Opt-in: Apprise alert when Longhorn backups or etcd snapshots are stale (copy application-template.yaml to apps/)
├── system-upgrade/                   # system-upgrade-controller (remote manifests via kustomize) + k3s upgrade Plans
│   ├── kustomization.yaml
│   └── plans.yaml
├── tailscale-operator/               # Tailscale Operator (opt-in — copy application-template.yaml to apps/)
│   ├── application-template.yaml    # Template Application — edit cluster_name, then copy to apps/
│   ├── oauth-secret.yaml            # ExternalSecret: OCI Vault → operator-oauth Secret
│   ├── proxyclass.yaml              # ProxyClass: resource limits for Tailscale proxy pods
│   └── kustomization.yaml
├── update-repo-url.sh                # Helper: update repoURL after forking (see below)
└── README.md
```

## Forking this repo

All `Application` manifests in `gitops/apps/` (and the `*/application-template.yaml`
files) contain a hardcoded `repoURL` pointing to
`https://github.com/mbologna/k3s-oci.git`. If you fork the repo, run the helper script
**once** after cloning to update all references:

```bash
bash gitops/update-repo-url.sh https://github.com/your-org/your-fork.git
git add gitops/ && git commit -m "chore: update gitops repoURL to fork"
git push
```

Then set `gitops_repo_url = "https://github.com/your-org/your-fork.git"` in your
`terraform.tfvars` so cloud-init bootstraps the App of Apps with the correct URL.

## Bootstrap vs ArgoCD responsibilities

Cloud-init bootstraps what ArgoCD cannot self-manage at first start:

| Component | Who manages it | Why |
|---|---|---|
| cert-manager Helm | cloud-init | ClusterIssuers need the real email from `var.certmanager_email_address` |
| ClusterIssuers (staging/prod) | cloud-init | Email is a runtime Terraform variable, not static git content |
| ArgoCD Helm + App of Apps | cloud-init | Chicken-and-egg: ArgoCD must be installed before it can manage itself |
| ESO Helm + ClusterSecretStore | cloud-init | `vault_ocid` is runtime; conditional on `enable_external_secrets` |
| Kubernetes Secrets with runtime values | cloud-init | Passwords, endpoints, OCI OCIDs resolved at `tofu apply` time |
| ArgoCD / Longhorn Ingresses + Certificates | cloud-init | NLB IP (sslip.io hostname, external-dns target) changes on every deploy; cannot be hardcoded in git |
| Traefik Helm | ArgoCD (`apps/traefik.yaml`) | Helm chart, no runtime variables |
| Longhorn Helm | ArgoCD (`apps/longhorn.yaml`) | Helm chart, no runtime variables |
| kured Helm | ArgoCD (`apps/kured.yaml`) | Helm chart, no runtime variables |
| system-upgrade-controller + Plans | ArgoCD (`apps/system-upgrade-controller.yaml`) | Remote release manifests via kustomize, no runtime variables |
| external-dns Helm | ArgoCD, Application created by cloud-init (`create_external_dns_app()`) | Needs runtime domain/zone filters; `optional/external-dns.yaml` is a reference |
| ESO Helm (adoption) | ArgoCD (`optional/external-secrets.yaml` via the `optional-external-secrets` wrapper) | Only when `enable_external_secrets = true` |
| All `gitops/network-policies/` resources | ArgoCD (`apps/network-policies.yaml`) | Pure Kubernetes manifests |
| `gitops/coredns/` HPA | ArgoCD (`apps/coredns.yaml`) | Pure Kubernetes manifests |
| `gitops/priority-classes/` | ArgoCD (`apps/priority-classes.yaml`) | Pure Kubernetes manifests |
| descheduler Helm | ArgoCD (`apps/descheduler.yaml`) | Helm chart, no runtime variables |

**Key rule**: if a resource needs a value that only exists after `tofu apply` (IP addresses, OCIDs, passwords), it goes in cloud-init. Everything else goes in `gitops/`.

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

## ArgoCD Image Updater (opt-in)

Image Updater is not installed by default: Renovate already bumps image tags in git, and the
updater does nothing until you create `ImageUpdater` resources. To install it, copy
`gitops/optional/argocd-image-updater.yaml` to `gitops/apps/`, then follow the
[Image Updater docs](https://argocd-image-updater.readthedocs.io/).

## TLS and ingress (Traefik)

Traefik (`apps/traefik.yaml`) terminates TLS with its TLSOption `default`: TLS 1.2+ and AES-GCM
suites cluster-wide. websecure (:443) is the default entrypoint, and :80 redirects to HTTPS
except for cert-manager's HTTP-01 solver.

To expose a new service over HTTPS, create a `Certificate` and an `Ingress` in the service's
namespace (an Ingress can only use a TLS Secret of its own namespace):

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-tls
  namespace: my-namespace
spec:
  secretName: myapp-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - myapp.example.com
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: my-namespace
  annotations:
    # Optional: Traefik Middlewares, comma-separated <namespace>-<name>@kubernetescrd
    # traefik.ingress.kubernetes.io/router.middlewares: my-namespace-myapp-auth@kubernetescrd
    # Optional, with enable_external_dns: the public NLB IP as the record target
    # external-dns.alpha.kubernetes.io/target: "<public-nlb-ip>"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - myapp.example.com
      secretName: myapp-tls
  rules:
    - host: myapp.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp-service
                port:
                  number: 8080
```

If the namespace has a default-deny ingress policy, allow the `traefik` namespace to reach the
service's pods, and to cert-manager's HTTP-01 solver pods on 8089
(`network-policies/argocd.yaml` shows both).

## Resilience: spread replicas across nodes

With 2 nodes available for user workloads, use `topologySpreadConstraints` so that pod replicas never pile up on a single node. Losing one node then kills at most ⌈replicas/2⌉ pods instead of all of them.

```yaml
# Add to every Deployment/StatefulSet with replicas > 1
spec:
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app: my-app   # match your pod labels
```

For lower-priority workloads where strict spreading is not required:

```yaml
      whenUnsatisfiable: ScheduleAnyway  # soft preference instead of hard requirement
```

Add a `PodDisruptionBudget` alongside to keep at least one replica up during voluntary disruptions (kured reboots, kubectl drain):

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
spec:
  minAvailable: 1   # or maxUnavailable: 1
  selector:
    matchLabels:
      app: my-app
```

> **etcd note:** etcd runs on a single control-plane node (no HA quorum). The cluster does not tolerate control-plane loss without manual recovery from an etcd snapshot. This is a constraint of the Always Free 2-node topology.
