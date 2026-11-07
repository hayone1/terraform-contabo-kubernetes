# A cluster with three storage workers that run the V2 Data Engine of
# Longhorn next to the default engine. The V2 Data Engine uses SPDK, a fast
# storage engine that works on a raw partition instead of a file system.
# Volumes of the storage class "longhorn-v2" use the new engine, and all
# other volumes keep the default engine (storage class "longhorn").

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
    product_id = var.control_plane_product_id
    count      = 1
  }]

  # Dedicated servers (VDS) have their own CPU cores. The V2 Data Engine keeps
  # 2 cores of every storage node busy.
  worker_pools = [{
    name       = "storage"
    product_id = var.worker_product_id
    count      = 3
  }]

  admin_access = {
    cidrs = var.admin_cidrs
  }

  # The workers get a raw partition of v2_size for the V2 Data Engine. The
  # rest of the disk (after 50 GiB for Talos) stays with the default engine.
  longhorn = {
    enabled = true
    v2 = {
      enabled        = true
      size           = var.v2_size
      interrupt_mode = var.interrupt_mode
    }
  }
}
