terraform {
  required_version = ">= 1.5.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.0"
    }
  }
}

# Auth is read automatically from ~/.oci/config (created by `oci setup config`).
# Only region is set here so it can be overridden without editing ~/.oci/config.
provider "oci" {
  tenancy_ocid           = var.tenancy_ocid
  user_ocid              = var.user_ocid
  fingerprint            = var.fingerprint
  private_key_path       = var.private_key_path
  region                 = var.region
  retry_duration_seconds = 300
}
