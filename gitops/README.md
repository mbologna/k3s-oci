# GitOps — the default applications

Argo CD syncs `gitops/apps/` through the App of Apps the servers create from `gitops_repo_url`,
`gitops_revision` and `gitops_path`. Fork the repository and run `gitops/update-repo-url.sh` to
point every `repoURL` at your fork, then add your own Applications to `apps/`.

```
gitops/
├── apps/                    the App of Apps (synced automatically)
│   ├── app-of-apps.yaml     manages itself once synced; keep repoURL equal to gitops_repo_url
│   ├── argocd.yaml          adopts the Helm release the first server installed (keep the
│   │                        chart version equal to argocd_chart_version)
│   ├── argocd-config.yaml   the rate-limit Middleware for an Argo CD Ingress (argocd/)
│   ├── cert-manager.yaml    cert-manager; the servers create the ClusterIssuers (certmanager_email)
│   ├── coredns.yaml         two CoreDNS replicas, one per node (coredns/)
│   ├── kured.yaml           reboots for OS updates: security on any night, the rest Tue-Thu
│   ├── longhorn.yaml        Longhorn, 2 replicas, the default StorageClass
│   ├── network-policies.yaml  default-deny NetworkPolicies and namespace PSA labels (network-policies/)
│   ├── priority-classes.yaml  platform-critical and alerting (priority-classes/)
│   ├── system-upgrade-controller.yaml  k3s upgrades: the Plan in system-upgrade/
│   └── traefik.yaml         Traefik DaemonSet on the NLB's NodePorts 30080/30443, HTTPS by default
├── optional/
│   ├── external-secrets.yaml  External Secrets Operator: copy to apps/ to install
│   └── fcos-os.yaml         Fedora CoreOS OS updates; the servers add it on fcos clusters
├── fcos-os/                 the fcos-os upgrade Plan: the FCOS release the cluster runs
├── external-secrets/        ClusterSecretStore (OCI Vault, API-key user) and an example
├── cert-manager/            the ClusterIssuers as manifests, and a DNS-01 variant
├── longhorn/                backup target steps, an Ingress with basic auth, taint tolerations
├── node-cordon-alert/       opt-in webhook alert when a node stays cordoned
└── tailscale-operator/      opt-in Tailscale operator, HA ProxyGroups, NetworkPolicies
```

Templates (`*application-template.yaml`, `longhorn/`, `cert-manager/`, `external-secrets/`) do
nothing until you copy or adapt them into a synced path; each says what to fill in.

Notes:

- Traefik serves only `websecure` by default; the HTTP-01 solver Ingress pins itself to `web`, and
  the `web` → HTTPS redirect sits below it (priority 1). Keep both, or HTTP-01 stops working.
- The NodePorts must equal `ingress_http_nodeport` / `ingress_https_nodeport`.
- Longhorn keeps 2 replicas: on two servers a third could never be scheduled.
- NetworkPolicies match the endpoint after kube-proxy's DNAT: the Kubernetes API is a node's
  private `:6443`, never the `kubernetes` Service's `:443`. Egress to `169.254.0.0/16` stays
  closed (the metadata service holds the node configuration), except DNS to the VCN resolver.
