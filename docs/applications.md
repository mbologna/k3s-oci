# Deploying applications

Ingress, TLS and DNS for your own workloads, and how to add them through Argo CD.

## Deploying a web application

### Why TLS is terminated at Traefik, not at the OCI load balancer

OCI provides two load balancer products with very different capabilities:

| | OCI Network Load Balancer (NLB) | OCI Flexible Load Balancer |
|---|---|---|
| OSI layer | **L4 (TCP passthrough)** | L7 (HTTP/HTTPS aware) |
| TLS termination | ❌ Not possible | ✅ Yes |
| Always Free | **1 NLB** | 1 × 10 Mbps |
| Used here | `nlb.tf`: public internet traffic | `lb.tf`: internal kubeapi endpoint |

The public-facing load balancer is the **NLB**. It forwards raw TCP streams with `protocol = "TCP"`, so it has no knowledge of TLS, HTTP headers, or certificates. TLS **must** be terminated by something behind it.

The **Flexible LB** *could* terminate TLS, but the one free allocation is already consumed by the internal kubeapi load balancer. Even if it were available, using OCI to manage certificates would break the automatic cert-manager + Let's Encrypt renewal cycle.

The current flow is: Internet → NLB (TCP passthrough, preserves client IPs) → Traefik NodePort (one pod per node) → TLS terminate → route to app pod.

How Traefik is set up (`gitops/apps/traefik.yaml`):

- **websecure is the default entrypoint.** An Ingress or IngressRoute without an explicit entrypoint is served on :443 only, with TLS.
- **:80 redirects to HTTPS** (permanent), at the lowest router priority, so cert-manager's HTTP-01 solver Ingress (pinned to the `web` entrypoint by the ClusterIssuers) still answers the ACME challenge there. To serve plain HTTP on purpose, pin an Ingress to `web` with the annotation `traefik.ingress.kubernetes.io/router.entrypoints: web`.
- **TLS 1.2+ with AES-GCM ciphers** (TLSOption `default`).
- **No Ingress status**: the NodePort Service has no load-balancer address, and `gitops/` stays IP-free. Argo CD treats an Ingress as Healthy without it; for external-dns, give your Ingress the `external-dns.alpha.kubernetes.io/target: <NLB_IP>` annotation (cloud-init does this for the ArgoCD and Longhorn Ingresses).

### Minimal example: HTTP-only

No domain needed. Requests to the NLB IP are served directly.

```yaml
# hello-web.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-web
  namespace: hello-web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello-web
  template:
    metadata:
      labels:
        app: hello-web
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: hello-web
      containers:
        - name: hello-web
          image: httpd:alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: hello-web
  namespace: hello-web
spec:
  selector:
    app: hello-web
  ports:
    - port: 80
      targetPort: 80
---
# Ingress without a host = matches every request; pinned to the web entrypoint
# (plain HTTP), where it outranks the HTTP->HTTPS redirect.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-web
  namespace: hello-web
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hello-web
                port:
                  number: 80
```

```bash
kubectl create namespace hello-web
kubectl apply -f hello-web.yaml
NLB_IP=$(cd example && tofu output -raw nlb_ip)
curl http://$NLB_IP/
```

### Minimal example: HTTPS with sslip.io (no domain purchase required)

[sslip.io](https://sslip.io) is a public DNS service that resolves `<anything>.<ip>.sslip.io` directly to `<ip>`. Combined with cert-manager + Let's Encrypt HTTP-01, this gives a trusted TLS certificate with zero infrastructure cost.

Replace `<NLB_IP>` with the value of `tofu output -raw nlb_ip`.

```yaml
# hello-web-tls.yaml
---
# 1. Certificate, issued over HTTP-01 through Traefik's web entrypoint. It lives
#    in the app's namespace: an Ingress can only use a TLS Secret of its own.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: hello-web-tls
  namespace: hello-web
spec:
  secretName: hello-web-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - hello-web.<NLB_IP>.sslip.io
---
# 2. Ingress on websecure (the default entrypoint); :80 redirects here already.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-web
  namespace: hello-web
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - hello-web.<NLB_IP>.sslip.io
      secretName: hello-web-tls
  rules:
    - host: hello-web.<NLB_IP>.sslip.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hello-web
                port:
                  number: 80
```

```bash
# Wait for certificate issuance (typically 1-2 minutes)
kubectl wait --for=condition=Ready certificate/hello-web-tls -n hello-web --timeout=5m
curl https://hello-web.<NLB_IP>.sslip.io/
```

Instead of a separate Certificate, you can annotate the Ingress with `cert-manager.io/cluster-issuer: letsencrypt-prod` and let cert-manager's ingress-shim create it from `spec.tls`.

Middlewares (BasicAuth, rate limits, IP allowlists, headers) are Traefik `Middleware` objects attached with `traefik.ingress.kubernetes.io/router.middlewares: <namespace>-<name>@kubernetescrd`; `gitops/argocd/rate-limit.yaml` and `gitops/longhorn/ingress.yaml` show two.

> **With a real domain**: set `enable_external_dns = true` and add the `target` annotation
> described above; External DNS creates the records, then cert-manager issues the certificate.
> `enable_dns01_challenge = true` switches to DNS-01 (wildcard certificates, no inbound port 80).

### DNS: lower ndots for Alpine (musl) images

Pods inherit the node's search domains (the OCI VCN's, plus any a node adds, e.g. Tailscale's)
after the cluster ones. With Kubernetes' default `ndots:5`, an external name such as `github.com`
is first tried against every search domain, and musl gives up when one of those lookups errors
(`EAI_AGAIN`, "DNS server returned general failure") instead of trying the next. Set
`ndots:1` on such workloads, and write in-cluster names fully qualified
(`kubernetes.default.svc.cluster.local`): musl does not apply the search list to a dotted name.

```yaml
spec:
  template:
    spec:
      dnsConfig:
        options:
          - name: ndots
            value: "1"
```

### Resilience: spread replicas across nodes

Run `replicas ≥ 2` with `topologySpreadConstraints` on `kubernetes.io/hostname` so losing one node never takes all replicas down. Traefik already runs on both nodes, so ingress survives a single-node drain or failure. See [gitops/README.md](../gitops/README.md#resilience-spread-replicas-across-nodes) for the snippet and a matching PodDisruptionBudget.

## GitOps, App of Apps

The `gitops/` directory contains ArgoCD `Application` manifests managed with the [App of Apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern).

After the cluster is running, bootstrap it:

```bash
kubectl apply -n argocd -f gitops/apps/app-of-apps.yaml
```

ArgoCD will then continuously reconcile every manifest under `gitops/apps/`.

### Keeping the Argo CD UI off the internet

By default cloud-init publishes the Argo CD UI on an sslip.io hostname behind the NLB. To reach it only
over your tailnet, set `argocd_hostname = ""` (no public route), deploy the Tailscale operator
(`gitops/tailscale-operator/`), and add a Service like this to your gitops repo. The Longhorn UI works
the same way (selector `app: longhorn-ui`, port 8000); leave `longhorn_hostname` unset.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-tailnet
  namespace: argocd
  annotations:
    tailscale.com/hostname: argocd   # http://argocd.<tailnet>.ts.net
    # tailscale.com/proxy-group: ingress-ha   # with the HA ProxyGroups
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  selector:
    app.kubernetes.io/instance: argocd
    app.kubernetes.io/name: argocd-server
  ports:
    - name: http
      port: 80
      targetPort: 8080
```

Plain HTTP is fine inside WireGuard (`server.insecure` is already on). CLI:
`argocd login argocd.<tailnet>.ts.net --plaintext --grpc-web`. The tailscale namespace's
NetworkPolicies let the proxy out; the UI's namespace must let it in: add a
`kubernetes.io/metadata.name: tailscale` namespace selector next to Traefik's in `allow-traefik-ingress`
(`gitops/network-policies/argocd.yaml`, `longhorn-system.yaml`).

### Adding your own applications

This repo is designed to be forked. To add your own apps on top of the built-in stack:

1. **Fork this repo** on GitHub.

2. **Update all `repoURL` references** to point to your fork:
   ```bash
   bash gitops/update-repo-url.sh https://github.com/your-org/your-fork.git
   git add gitops/ && git commit -m "chore: update gitops repoURL"
   git push
   ```

3. **Add your ArgoCD `Application` manifests** to `gitops/apps/`, ArgoCD syncs them automatically. Each app can point at any Helm chart registry or any Git repository.

> **Deploying for the first time?** Also set `gitops_repo_url` in `terraform.tfvars` before running `tofu apply`, so cloud-init writes the correct fork URL at bootstrap:
> ```hcl
> gitops_repo_url = "https://github.com/your-org/your-fork.git"
> ```
> **Already have a running cluster?** Patch the App of Apps directly:
> ```bash
> argocd app set app-of-apps --repo https://github.com/your-org/your-fork.git
> ```

> **Private repos**: two auth methods, both storing the credential in OCI Vault automatically so cloud-init can create the `argocd-repo-gitops` Secret before ArgoCD starts. No manual `argocd repo add` step needed.
>
> - **SSH**: set `gitops_ssh_private_key` with your deploy key.
> - **HTTPS token**: set `gitops_https_username` + `gitops_https_token` (read-only repository scope; ArgoCD never writes). Takes precedence over the SSH key when both are set.
>
> Prefer the HTTPS token if your git host throttles SSH per source IP. ArgoCD is a heavy SSH client, every Application opens its own `git ls-remote`, and the resulting connection bursts can trip such limits and stall GitOps entirely, with apps stuck reporting `sync.revision` as `HEAD` rather than a SHA. Codeberg does this; GitHub and GitLab generally do not.
>
> For repos with a non-standard directory layout, set `gitops_path` (default: `gitops/apps`).
>
> With `enable_external_secrets = true`, cloud-init also creates an `optional-external-secrets` Application that reads
> `external-secrets.yaml` from `gitops_optional_path` (default: `gitops/optional`) in the same repo. If your repo
> manages ESO itself, set `gitops_optional_path = ""`: cloud-init still installs ESO but creates no wrapper.
>
> Repos that wrap Helm charts in kustomize (`helmCharts:` in a `kustomization.yaml`) work out of the box: Argo CD
> starts with `kustomize.buildOptions: --enable-helm`.
