# gitops/monitoring — supplementary monitoring resources

This directory contains extra Kubernetes manifests for the monitoring stack, managed by the `monitoring-extras` ArgoCD Application (`gitops/apps/monitoring-extras.yaml`).

The core stack (Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics) is deployed by `gitops/apps/kube-prometheus-stack.yaml` as a Helm release.

## Files

| File | Description |
|---|---|
| `grafana-ingress.yaml` | Traefik IngressRoute + cert-manager Certificate for Grafana UI |
| `prometheus-rules.yaml` | PrometheusRule alerts for node disk pressure and Longhorn volume health |

## Grafana access

1. Update the hostname in `grafana-ingress.yaml` to match your `grafana_hostname` Terraform variable.
2. Commit and push — ArgoCD will create the IngressRoute and request a TLS certificate.
3. Retrieve the admin password: `terraform output -raw grafana_admin_credentials`

When `enable_vault = true` (default), the password is fetched from OCI Vault at boot and pre-created as the `grafana-admin-secret` Kubernetes Secret. The `terraform output` value and the Secret are always in sync.

## Adding Grafana dashboards

Add dashboards as ConfigMaps with the label `grafana_dashboard: "1"`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  my-dashboard.json: |
    { ... grafana dashboard JSON ... }
```

Grafana sidecar picks up ConfigMaps with this label automatically.

## Adding Alertmanager receivers

The `alertmanager-oci-config` Secret in the `monitoring` namespace is always pre-created by cloud-init (via `kube-prometheus-stack.yaml`'s `alertmanagerSpec.configSecret`). When `enable_notifications = true` in Terraform, this secret already contains a working OCI Notifications webhook receiver. When disabled, it contains a null-route config.

To add additional receivers (Slack, PagerDuty, etc.), replace the secret or add namespace-scoped `AlertmanagerConfig` CRs:

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: slack-receiver
  namespace: monitoring
spec:
  route:
    receiver: slack
    matchers:
      - name: alertname
        value: NodeDiskSpaceLow
  receivers:
    - name: slack
      slackConfigs:
        - apiURL:
            key: url
            name: slack-webhook-secret
          channel: "#alerts"
```
