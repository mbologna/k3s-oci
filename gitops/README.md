# GitOps — App of Apps

This directory contains ArgoCD `Application` manifests managed via the [App of Apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern).

## Structure

```
gitops/
├── apps/                             # ArgoCD Application manifests (App of Apps root)
│   ├── app-of-apps.yaml              # Root Application — bootstrapped by cloud-init
│   ├── argocd.yaml                   # ArgoCD Helm release
│   ├── argocd-config.yaml            # ArgoCD supplementary config (BackendTrafficPolicy rate-limit)
│   ├── argocd-image-updater.yaml     # ArgoCD Image Updater Helm release
│   ├── cert-manager.yaml             # cert-manager Helm release
│   ├── envoy-gateway.yaml            # Envoy Gateway Helm release (OCI registry)
│   ├── external-dns.yaml             # External DNS Helm release (optional)
│   ├── external-secrets.yaml         # External Secrets Operator Helm release (optional)
│   ├── gateway-config.yaml           # Envoy Gateway config manifests (gitops/gateway/)
│   ├── kube-prometheus-stack.yaml    # Prometheus + Grafana + Alertmanager (Helm)
│   ├── kured.yaml                    # kured Helm release
│   ├── longhorn.yaml                 # Longhorn Helm release
│   ├── monitoring-extras.yaml        # PrometheusRules, ServiceMonitor, Grafana HTTPRoute
│   ├── network-policies.yaml         # NetworkPolicies for all namespaces
│   ├── pdbs.yaml                     # PodDisruptionBudgets for core components
│   └── system-upgrade-controller.yaml # system-upgrade-controller for k3s upgrades
├── argocd/                           # ArgoCD supplementary config
│   └── rate-limit.yaml               # Envoy Gateway BackendTrafficPolicy (100 req/s/IP for ArgoCD UI)
├── cert-manager/                     # ClusterIssuer templates (see adoption notes)
│   ├── cluster-issuers.yaml          # Template — update email before using
│   └── application-template.yaml    # Copy to apps/ after updating email
├── external-secrets/                 # External Secrets templates
│   ├── cluster-secret-store-template.yaml  # ClusterSecretStore backed by OCI Vault
│   └── example-external-secrets.yaml       # Example ExternalSecret CRs
├── gateway/                          # Envoy Gateway configuration
│   ├── envoy-proxy.yaml              # EnvoyProxy: DaemonSet, NodePorts 30080/30443, PDB
│   ├── gateway-class.yaml            # GatewayClass pointing to proxy-config
│   ├── gateway.yaml                  # Gateway with HTTP listener + commented HTTPS listeners
│   ├── redirect.yaml                 # HTTP→HTTPS RequestRedirect HTTPRoute
│   └── tls-policy.yaml               # ClientTrafficPolicy: TLS 1.2+, strong ciphers
├── longhorn/                         # Longhorn supplementary config
│   ├── ingress.yaml                  # HTTPRoute + SecurityPolicy (BasicAuth) template
│   ├── backup-target.yaml            # OCI Object Storage backup target template (see file for setup)
│   ├── taint-toleration.yaml         # Worker node NoSchedule taint Setting template (uncomment + set taint key)
│   └── webhook-postsync/             # ArgoCD PostSync hook — patches webhook failurePolicy to Ignore
│       ├── kustomization.yaml        #   after each Helm sync (workaround: k3s HA konnectivity 502)
│       ├── rbac.yaml                 #   ServiceAccount + ClusterRole + ClusterRoleBinding
│       └── webhook-patch-job.yaml    #   Job with hardened securityContext; backoffLimit:0
├── monitoring/                       # Supplementary monitoring resources
│   ├── alertmanager-config.yaml      # AlertmanagerConfig template (Slack/email/webhook)
│   ├── grafana-ingress.yaml          # Gateway API HTTPRoute for Grafana (update hostname)
│   ├── longhorn-servicemonitor.yaml  # ServiceMonitor for Longhorn metrics scraping
│   ├── prometheus-rules.yaml         # Disk + Longhorn alert rules
│   └── README.md                     # Grafana access, dashboards, alerting how-to
├── network-policies/                 # NetworkPolicies (default-deny + allow rules per namespace)
│   ├── default-deny.yaml             # default namespace
│   ├── argocd.yaml                   # argocd namespace (includes port 22 SSH egress for git clone)
│   ├── cert-manager.yaml             # cert-manager namespace (includes port 80 egress for HTTP-01)
│   ├── envoy-gateway-system.yaml     # envoy-gateway-system namespace (NodePort ingress + backend egress)
│   ├── longhorn-system.yaml          # longhorn-system namespace
│   ├── monitoring.yaml               # monitoring namespace
│   └── system-upgrade.yaml           # system-upgrade namespace
├── pdbs/                             # PodDisruptionBudgets
│   └── pod-disruption-budgets.yaml   # ArgoCD, cert-manager PDBs
├── tailscale-operator/               # Tailscale Operator (opt-in — copy application-template.yaml to apps/)
│   ├── application-template.yaml    # Template Application — edit cluster_name, then copy to apps/
│   ├── oauth-secret.yaml            # ExternalSecret: OCI Vault → operator-oauth Secret
│   ├── proxyclass.yaml              # ProxyClass: resource limits for Tailscale proxy pods
│   └── kustomization.yaml
├── update-repo-url.sh                # Helper: update repoURL after forking (see below)
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

## Bootstrap vs ArgoCD responsibilities

Cloud-init bootstraps what ArgoCD cannot self-manage at first start:

| Component | Who manages it | Why |
|---|---|---|
| Gateway API CRDs | cloud-init | Must exist before ArgoCD syncs `envoy-gateway` and `gateway-config` |
| cert-manager Helm | cloud-init | ClusterIssuers need the real email from `var.certmanager_email_address` |
| ClusterIssuers (staging/prod) | cloud-init | Email is a runtime Terraform variable, not static git content |
| ArgoCD Helm + App of Apps | cloud-init | Chicken-and-egg: ArgoCD must be installed before it can manage itself |
| ESO Helm + ClusterSecretStore | cloud-init | `vault_ocid` is runtime; conditional on `enable_external_secrets` |
| Kubernetes Secrets with runtime values | cloud-init | Passwords, endpoints, OCI OCIDs resolved at `tofu apply` time |
| `https-grafana` / `https-argocd` / `https-longhorn` Gateway listeners | cloud-init | NLB IP changes on every deploy; cannot be hardcoded in git |
| Envoy Gateway Helm | ArgoCD (`apps/envoy-gateway.yaml`) | Helm chart, no runtime variables |
| Longhorn Helm | ArgoCD (`apps/longhorn.yaml`) | Helm chart, no runtime variables |
| kured Helm | ArgoCD (`apps/kured.yaml`) | Helm chart, no runtime variables |
| system-upgrade-controller Helm | ArgoCD (`apps/system-upgrade-controller.yaml`) | Helm chart, no runtime variables |
| external-dns Helm | ArgoCD (`apps/external-dns.yaml`) or optional-external-dns wrapper | Helm chart |
| All `gitops/gateway/` resources | ArgoCD (`apps/gateway-config.yaml`) | Pure Kubernetes manifests, no runtime values |
| All `gitops/network-policies/` resources | ArgoCD (`apps/network-policies.yaml`) | Pure Kubernetes manifests |
| All `gitops/pdbs/` resources | ArgoCD (`apps/pdbs.yaml`) | Pure Kubernetes manifests |

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

## TLS (Gateway API)

TLS is managed via Envoy Gateway's `ClientTrafficPolicy` in `gitops/gateway/tls-policy.yaml`,
which enforces TLS 1.2+ and strong cipher suites cluster-wide.

To expose a new service over HTTPS:

1. Add an HTTPS listener to `gitops/gateway/gateway.yaml`:
   ```yaml
   - name: https-myapp
     port: 443
     protocol: HTTPS
     hostname: "myapp.example.com"
     tls:
       mode: Terminate
       certificateRefs:
         - name: myapp-tls
     allowedRoutes:
       namespaces:
         from: All
   ```

2. Create a `Certificate` resource in the `envoy-gateway-system` namespace
   (same namespace as the Gateway — no `ReferenceGrant` needed):
   ```yaml
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata:
     name: myapp-tls
     namespace: envoy-gateway-system
   spec:
     secretName: myapp-tls
     issuerRef:
       name: letsencrypt-prod
       kind: ClusterIssuer
     dnsNames:
       - myapp.example.com
   ```

3. Create an `HTTPRoute` in your application's namespace:
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: myapp
     namespace: my-namespace
   spec:
     parentRefs:
       - name: eg
         namespace: envoy-gateway-system
         sectionName: https-myapp
     hostnames:
       - "myapp.example.com"
     rules:
       - backendRefs:
           - name: myapp-service
             port: 8080
   ```

## Resilience: spread replicas across nodes

With 4 nodes available for user workloads, use `topologySpreadConstraints` so that pod replicas never pile up on a single node. Losing one node then kills at most ⌈replicas/4⌉ pods instead of all of them.

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
