# Offline render test: the OCI provider is mocked, so this needs no tenancy. It
# renders every os_family's node configuration and checks what OCI and the
# nodes would reject: user_data over 32,000 bytes, Ignition that is not version
# 3.4.0 JSON, a k3s config without the datastore it was asked for.

mock_provider "oci" {
  mock_data "oci_identity_regions" {
    defaults = {
      regions = [{ key = "PHX", name = "us-phoenix-1" }]
    }
  }
  mock_data "oci_core_services" {
    defaults = {
      services = [{ id = "ocid1.service.oc1.phx.mock", cidr_block = "all-phx-services-in-oracle-services-network", description = "", name = "All PHX Services In Oracle Services Network" }]
    }
  }
  mock_data "oci_objectstorage_namespace" {
    defaults = { namespace = "mocknamespace" }
  }
  mock_resource "oci_load_balancer_load_balancer" {
    defaults = {
      ip_address_details = [{ ip_address = "10.0.1.5", is_public = false, reserved_ip = [] }]
    }
  }
  mock_resource "oci_mysql_mysql_db_system" {
    defaults = { ip_address = "10.0.1.20" }
  }
  mock_resource "oci_objectstorage_preauthrequest" {
    defaults = { full_path = "https://objectstorage.us-phoenix-1.oraclecloud.com/p/mock/n/mocknamespace/b/k3s-oci-backups/o/k3s-oci/server-0.sh" }
  }
  mock_resource "oci_network_load_balancer_network_load_balancer" {
    defaults = {
      ip_addresses = [{ ip_address = "203.0.113.10", is_public = true, ip_version = "IPV4", reserved_ip = [] }]
    }
  }
}

variables {
  tenancy_ocid        = "ocid1.tenancy.oc1..mock"
  compartment_ocid    = "ocid1.tenancy.oc1..mock"
  availability_domain = "Mock:PHX-AD-1"
  image_id            = "ocid1.image.oc1.phx.mock"
  ssh_public_key      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockMockMockMockMockMockMockMockMockMockMock test"
  certmanager_email   = "admin@example.com"
  gitops_https_token  = "mock-token"
}

run "opensuse_mysql" {
  command = apply

  assert {
    condition     = alltrue([for ud in local.user_data : length(ud) < 32000])
    error_message = "opensuse user_data is over 32,000 bytes."
  }
  assert {
    condition     = strcontains(local.node_script["server-0"], "two_phase_begin opensuse_install")
    error_message = "the opensuse script lacks its bootstrap."
  }
  assert {
    condition     = yamldecode(base64decode(regex("K3S_CONFIG_B64=\"([^\"]+)\"", local.node_script["server-1"])[0]))["datastore-endpoint"] == "mysql://k3s:${random_password.mysql_admin[0].result}@tcp(10.0.1.20:3306)/k3s"
    error_message = "the k3s config does not point kine at the database."
  }
  assert {
    condition     = length([for d in split("\n---\n", local.bootstrap_manifests) : d if yamldecode(d).kind == "ClusterIssuer"]) == 2 && contains([for d in split("\n---\n", local.bootstrap_manifests) : yamldecode(d).metadata.name], "app-of-apps")
    error_message = "the bootstrap manifests lack the App of Apps or the ClusterIssuers."
  }
}

run "fcos_ignition" {
  command = apply

  variables {
    os_family = "fcos"
  }

  assert {
    condition     = alltrue([for ud in local.user_data : length(ud) < 32000])
    error_message = "fcos user_data is over 32,000 bytes."
  }
  assert {
    condition     = jsondecode(base64decode(local.user_data["server-0"])).ignition.version == "3.4.0"
    error_message = "fcos user_data is not Ignition 3.4.0."
  }
  assert {
    condition     = contains([for u in jsondecode(base64decode(local.user_data["server-0"])).systemd.units : u.name], "zincati.service")
    error_message = "Zincati is not masked on fcos."
  }
  assert {
    condition     = strcontains(local.node_script["server-0"], "two_phase_begin fcos_install")
    error_message = "the fcos script lacks its bootstrap."
  }
  assert {
    condition     = contains([for d in split("\n---\n", local.bootstrap_manifests) : yamldecode(d).metadata.name], "optional-fcos-os")
    error_message = "fcos clusters do not get the fcos-os Application."
  }
}

run "flatcar_ignition" {
  command = apply

  variables {
    os_family = "flatcar"
  }

  assert {
    condition     = alltrue([for ud in local.user_data : length(ud) < 32000])
    error_message = "flatcar user_data is over 32,000 bytes."
  }
  assert {
    condition     = contains([for f in jsondecode(base64decode(local.user_data["server-0"])).storage.files : f.path], "/opt/extensions/k3s/k3s-${var.k3s_version}-arm64.raw")
    error_message = "flatcar Ignition lacks the k3s system extension."
  }
  assert {
    condition     = contains([for u in jsondecode(base64decode(local.user_data["server-0"])).systemd.units : u.name], "locksmithd.service")
    error_message = "locksmithd is not masked on flatcar."
  }
}

run "etcd_three_servers" {
  command = apply

  variables {
    datastore = "etcd"
    nodes = {
      server-0 = { ocpus = 2, memory_gbs = 8, boot_gb = 67, fault_domain = "FAULT-DOMAIN-1", ip_host = 10 }
      server-1 = { ocpus = 1, memory_gbs = 8, boot_gb = 67, fault_domain = "FAULT-DOMAIN-2", ip_host = 11 }
      server-2 = { ocpus = 1, memory_gbs = 8, boot_gb = 66, fault_domain = "FAULT-DOMAIN-3", ip_host = 12 }
    }
  }

  assert {
    condition     = local.k3s_config["server-0"]["cluster-init"] == true && local.k3s_config["server-2"]["server"] == "https://10.0.1.10:6443"
    error_message = "etcd: server-0 does not start the cluster, or server-2 does not join it."
  }
  assert {
    condition     = !contains(keys(local.k3s_config["server-1"]), "datastore-endpoint")
    error_message = "etcd mode still points at a database."
  }
}
