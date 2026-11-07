# The smallest production-style cluster: one control plane node that also runs
# the workloads. The module orders the instance, a private network and a
# firewall, installs Talos, and installs Cilium, the Talos cloud controller
# manager and metrics-server.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    contabo = {
      source  = "hayone1/contabo"
      version = ">= 0.3.4, < 0.4.0"
    }
  }
}

# The provider reads the Contabo API credentials from the environment
# variables CNTB_OAUTH2_CLIENT_ID, CNTB_OAUTH2_CLIENT_SECRET, CNTB_OAUTH2_USER
# and CNTB_OAUTH2_PASS.
provider "contabo" {}

module "kubernetes" {
  # Use a version tag of the repository in your own configuration, for example
  # "git::https://github.com/hayone1/terraform-contabo-kubernetes.git?ref=v0.1.0".
  source = "../.."

  cluster_name = var.cluster_name
  region       = var.region

  control_plane_pools = [{
    name       = "cp"
    product_id = var.product_id
    count      = 1
  }]

  # The computer that runs Terraform may always reach the APIs. Add the
  # addresses of other administrators here.
  admin_access = {
    cidrs = var.admin_cidrs
  }
}
