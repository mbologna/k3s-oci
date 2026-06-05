# moved.tf — Terraform resource address migration history.
# When renaming a resource, add a moved {} block here and remove it after one release.

# nlb.tf: collapsed k3s_http / k3s_https backend_sets and listeners into for_each
moved {
  from = oci_network_load_balancer_backend_set.k3s_http
  to   = oci_network_load_balancer_backend_set.k3s_web["http"]
}
moved {
  from = oci_network_load_balancer_backend_set.k3s_https
  to   = oci_network_load_balancer_backend_set.k3s_web["https"]
}
moved {
  from = oci_network_load_balancer_listener.k3s_http
  to   = oci_network_load_balancer_listener.k3s_web["http"]
}
moved {
  from = oci_network_load_balancer_listener.k3s_https
  to   = oci_network_load_balancer_listener.k3s_web["https"]
}

# nlb.tf: refactored count-based NLB backends into for_each by node tier × protocol
moved {
  from = oci_network_load_balancer_backend.k3s_http_standalone_worker[0]
  to   = oci_network_load_balancer_backend.k3s_standalone["http"]
}
moved {
  from = oci_network_load_balancer_backend.k3s_https_standalone_worker[0]
  to   = oci_network_load_balancer_backend.k3s_standalone["https"]
}
moved {
  from = oci_network_load_balancer_backend.k3s_http_servers[0]
  to   = oci_network_load_balancer_backend.k3s_servers["http_0"]
}
moved {
  from = oci_network_load_balancer_backend.k3s_http_servers[1]
  to   = oci_network_load_balancer_backend.k3s_servers["http_1"]
}
moved {
  from = oci_network_load_balancer_backend.k3s_http_servers[2]
  to   = oci_network_load_balancer_backend.k3s_servers["http_2"]
}
moved {
  from = oci_network_load_balancer_backend.k3s_https_servers[0]
  to   = oci_network_load_balancer_backend.k3s_servers["https_0"]
}
moved {
  from = oci_network_load_balancer_backend.k3s_https_servers[1]
  to   = oci_network_load_balancer_backend.k3s_servers["https_1"]
}
moved {
  from = oci_network_load_balancer_backend.k3s_https_servers[2]
  to   = oci_network_load_balancer_backend.k3s_servers["https_2"]
}

# vault.tf: collapsed k3s_token, longhorn_ui_password, grafana_admin_password
# into a single for_each resource oci_vault_secret.cluster
moved {
  from = oci_vault_secret.k3s_token[0]
  to   = oci_vault_secret.cluster["k3s_token"]
}
moved {
  from = oci_vault_secret.longhorn_ui_password[0]
  to   = oci_vault_secret.cluster["longhorn_ui_password"]
}
moved {
  from = oci_vault_secret.grafana_admin_password[0]
  to   = oci_vault_secret.cluster["grafana_admin_password"]
}
