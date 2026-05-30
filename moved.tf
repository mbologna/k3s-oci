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
