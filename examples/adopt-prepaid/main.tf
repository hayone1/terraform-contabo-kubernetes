# A cluster from instances that you already pay for. The module erases the
# instances, installs Talos, and never cancels them: "terraform destroy" only
# forgets them, and they keep running and costing money.
#
# The example also orders two new workers. Remove the worker pool if you only
# want to use your own instances.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    contabo = {
      source  = "hayone1/contabo"
      version = ">= 0.3.4, < 0.4.0"
    }
  }
}

provider "contabo" {}

module "kubernetes" {
  source = "../.."

  cluster_name = var.cluster_name
  region       = var.region

  # The keys ("a", "b", "c") become part of the node names, for example
  # "prod-cp-a". Removing one entry later never renames the other nodes.
  control_plane_pools = [{
    name               = "cp"
    existing_instances = var.control_plane_instance_ids
  }]

  worker_pools = var.worker_count == 0 ? [] : [{
    name       = "worker"
    product_id = var.worker_product_id
    count      = var.worker_count
  }]

  adoption = {
    # Required: adoption erases the disks of the instances.
    allow_reinstall   = true
    cancel_on_destroy = false
  }

  admin_access = {
    cidrs = var.admin_cidrs
  }
}
