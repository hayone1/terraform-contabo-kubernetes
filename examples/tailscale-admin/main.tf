# A cluster whose Kubernetes API is only reachable through a tailnet. The
# Tailscale Terraform provider creates the credentials that the module needs:
#
# - an OAuth client for the node agent. Its secret never expires, so new nodes
#   can join the tailnet years later.
# - an OAuth client for the Tailscale operator and its API server proxy.
#
# With manage_tailnet = true, the example also owns the tailnet policy (tags
# and grants) and turns on HTTPS for the tailnet.

locals {
  base_policy   = jsondecode(var.base_policy)
  module_policy = jsondecode(module.kubernetes.tailscale_policy)

  # The tags and grants of the module, merged into base_policy.
  policy = merge(local.base_policy, {
    tagOwners = merge(try(local.base_policy.tagOwners, {}), local.module_policy.tagOwners)
    grants    = concat(try(local.base_policy.grants, []), local.module_policy.grants)
  })
}

resource "tailscale_acl" "this" {
  count = var.manage_tailnet ? 1 : 0

  acl = jsonencode(local.policy)
  # The policy replaces the current policy of the tailnet. See base_policy.
  overwrite_existing_content = true
}

resource "tailscale_tailnet_settings" "this" {
  count = var.manage_tailnet ? 1 : 0

  # The API server proxy serves a Let's Encrypt certificate for its tailnet
  # name. Tailscale then publishes the names of the devices with HTTPS
  # certificates in the public Certificate Transparency logs.
  https_enabled = true
}

# The nodes join the tailnet with the secret of this client. The tags of a
# client must exist in the tailnet policy first.
resource "tailscale_oauth_client" "nodes" {
  description = "${var.cluster_name} nodes"
  scopes      = ["auth_keys"]
  tags        = ["tag:k8s-node"]

  depends_on = [tailscale_acl.this]
}

resource "tailscale_oauth_client" "operator" {
  description = "${var.cluster_name} operator"
  scopes      = ["devices:core", "auth_keys", "services"]
  tags        = ["tag:k8s-operator"]

  depends_on = [tailscale_acl.this]
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

  tailscale = {
    tailnet_domain = var.tailnet_domain
    admin_sources  = var.admin_sources
    node_agent     = { enabled = true, tags = ["tag:k8s-node"] }
    operator       = { enabled = true, tags = ["tag:k8s-operator"], proxy_tags = ["tag:k8s"] }
  }

  # The parameters turn the client secret into an auth key for devices that
  # stay in the tailnet and need no approval.
  tailscale_auth_key = "${tailscale_oauth_client.nodes.key}?ephemeral=false&preauthorized=true"

  tailscale_oauth_client = {
    client_id     = tailscale_oauth_client.operator.id
    client_secret = tailscale_oauth_client.operator.key
  }
}
