# State migration: resource address renames
# These blocks allow existing Terraform state to be updated without destroying
# and recreating resources when resource names change between releases.

moved {
  from = oci_core_instance.k3s_extra_worker
  to   = oci_core_instance.k3s_standalone_worker
}

moved {
  from = oci_network_load_balancer_backend.k3s_http_extra_worker
  to   = oci_network_load_balancer_backend.k3s_http_standalone_worker
}

moved {
  from = oci_network_load_balancer_backend.k3s_https_extra_worker
  to   = oci_network_load_balancer_backend.k3s_https_standalone_worker
}
