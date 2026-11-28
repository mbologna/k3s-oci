# The cluster's server and client CAs, made here instead of by k3s at first
# start: the node script places them in /var/lib/rancher/k3s/server/tls/ before
# k3s starts (k3s keeps CA files it finds and generates the rest), so Terraform
# can hand out an admin kubeconfig without fetching anything from a node, and a
# rebuilt cluster keeps its CA as long as the state does. The keys are part of
# the node configuration, like the cluster token (SECURITY.md).

resource "tls_private_key" "ca" {
  for_each = toset(["server", "client"])

  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "ca" {
  for_each = tls_private_key.ca

  private_key_pem       = each.value.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 87600
  allowed_uses          = ["cert_signing", "crl_signing", "digital_signature", "key_encipherment"]

  subject {
    common_name = "k3s-${each.key}-ca@${var.cluster_name}"
  }
}

# Admin client certificate (system:masters), one year, renewed by any apply in
# its last 30 days: the kubeconfig output changes, nothing on the nodes does.
resource "tls_private_key" "admin" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "admin" {
  private_key_pem = tls_private_key.admin.private_key_pem

  subject {
    common_name  = "k3s-oci-admin"
    organization = "system:masters"
  }
}

resource "tls_locally_signed_cert" "admin" {
  cert_request_pem      = tls_cert_request.admin.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca["client"].private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca["client"].cert_pem
  validity_period_hours = 8760
  early_renewal_hours   = 720
  allowed_uses          = ["digital_signature", "key_encipherment", "client_auth"]
}

locals {
  # Through scripts/tunnel.sh: 127.0.0.1 is in every server's certificate.
  kubeconfig = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = var.cluster_name
    clusters = [{
      name = var.cluster_name
      cluster = {
        server                     = "https://127.0.0.1:6443"
        certificate-authority-data = base64encode(tls_self_signed_cert.ca["server"].cert_pem)
      }
    }]
    users = [{
      name = "${var.cluster_name}-admin"
      user = {
        client-certificate-data = base64encode(tls_locally_signed_cert.admin.cert_pem)
        client-key-data         = base64encode(tls_private_key.admin.private_key_pem)
      }
    }]
    contexts = [{
      name    = var.cluster_name
      context = { cluster = var.cluster_name, user = "${var.cluster_name}-admin" }
    }]
  })

  # The CA files for /var/lib/rancher/k3s/server/tls/: "<name> <base64 PEM>" per
  # line, which the node script reads without anything beyond coreutils.
  ca_files = join("\n", [for name, pem in {
    "server-ca.crt" = tls_self_signed_cert.ca["server"].cert_pem
    "server-ca.key" = tls_private_key.ca["server"].private_key_pem
    "client-ca.crt" = tls_self_signed_cert.ca["client"].cert_pem
    "client-ca.key" = tls_private_key.ca["client"].private_key_pem
  } : "${name} ${base64encode(pem)}"])
}
