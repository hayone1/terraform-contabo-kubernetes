# A cluster whose Kubernetes API is only reachable through a tailnet of your
# own Headscale server. Headscale is a control server for Tailscale clients
# that you run yourself. The Headscale Terraform provider creates the pre-auth
# key that the node agent needs.
#
# With manage_policy = true, the example also owns the policy of the Headscale
# server (groups, tags and grants).

locals {
  base_policy   = jsondecode(var.base_policy)
  module_policy = jsondecode(module.kubernetes.tailscale_policy)

  # The tags and grants of the module, merged into base_policy.
  policy = merge(local.base_policy, {
    tagOwners = merge(try(local.base_policy.tagOwners, {}), local.module_policy.tagOwners)
    grants    = concat(try(local.base_policy.grants, []), local.module_policy.grants)
  })
}

resource "headscale_policy" "this" {
  count = var.manage_policy ? 1 : 0

  # The policy replaces the current policy of the server. See base_policy.
  policy = jsonencode(local.policy)
}

# The nodes join the tailnet with this key. The key carries the node tag, so
# the nodes belong to no user. Headscale needs the tag in the policy first.
# A key cannot change: a new key_lifetime creates a new key.
resource "headscale_pre_auth_key" "nodes" {
  reusable       = true
  acl_tags       = ["tag:k8s-node"]
  time_to_expire = var.key_lifetime

  depends_on = [headscale_policy.this]
}

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

  # The Kubernetes API is closed on the public address. The Talos API stays
  # open for the computer that runs Terraform and admin_cidrs, because a new
  # node gets its first configuration through its public address.
  admin_access = {
    mode  = "tailscale"
    cidrs = var.admin_cidrs
  }

  # Headscale has no OAuth clients, so the Tailscale operator stays off.
  tailscale = {
    tailnet_domain = var.tailnet_domain
    login_server   = var.headscale_url
    admin_sources  = var.admin_sources
    tag_owners     = var.tag_owners
    node_agent     = { enabled = true, tags = ["tag:k8s-node"] }
  }

  tailscale_auth_key = headscale_pre_auth_key.nodes.key
}
