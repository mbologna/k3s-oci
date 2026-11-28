locals {
  common_tags = merge({ cluster = var.cluster_name, managed-by = "k3s-oci" }, var.freeform_tags)

  node_ips = { for name, node in var.nodes : name => cidrhost(var.private_subnet_cidr, node.ip_host) }

  # The first node by name starts an etcd cluster (datastore = "etcd") and
  # bootstraps Argo CD; the others join it.
  first_node = sort(keys(var.nodes))[0]
  first_ip   = local.node_ips[local.first_node]

  # The internal load balancer fronts the Kubernetes API of every server.
  lb_ip = oci_load_balancer_load_balancer.internal.ip_address_details[0].ip_address

  os_user = { opensuse = "sles", fcos = "core", flatcar = "core" }[var.os_family]

  # Ignition-based OSes fetch the node script through a pre-authenticated
  # request; cloud-init (opensuse) gets it in user_data.
  uses_ignition = contains(["fcos", "flatcar"], var.os_family)

  kine_endpoint = var.datastore == "mysql" ? format(
    "mysql://k3s:%s@tcp(%s:3306)/k3s",
    random_password.mysql_admin[0].result,
    oci_mysql_mysql_db_system.k3s[0].ip_address,
  ) : ""
}

resource "random_password" "k3s_token" {
  length  = 48
  special = false
}
