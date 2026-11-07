resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version

  lifecycle {
    # New secrets would make a new cluster. A Talos upgrade keeps the secrets.
    ignore_changes = [talos_version]
  }
}

locals {
  # lookup() keeps a removed bootstrap node from failing with an unclear
  # message. The precondition in talos_machine_configuration_apply explains
  # the problem.
  bootstrap_public_ipv4  = lookup(local.public_ipv4, local.bootstrap_key, "")
  bootstrap_private_ipv4 = lookup(local.private_ipv4, local.bootstrap_key, "")

  # Nodes reach the API server through the private network. KubePrism adds
  # the other control plane nodes, so this address is not a single point of
  # failure inside the cluster.
  cluster_endpoint = "https://${local.bootstrap_private_ipv4}:6443"

  # In the tailscale mode, the kubeconfig uses the tailnet name of the first
  # control plane node.
  kubernetes_api_host = (
    var.api_hostname != null ? var.api_hostname :
    local.tailscale_mode ? lookup(local.tailnet_names, local.bootstrap_key, "") : local.bootstrap_public_ipv4
  )
  kubernetes_api_url = "https://${local.kubernetes_api_host}:6443"

  control_plane_public_ipv4  = [for key in local.control_plane_keys : local.public_ipv4[key]]
  control_plane_private_ipv4 = [for key in local.control_plane_keys : local.private_ipv4[key]]
  worker_private_ipv4        = [for key in local.worker_keys : local.private_ipv4[key]]
}

data "talos_machine_configuration" "node" {
  for_each = local.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = each.value.role
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  config_patches     = local.node_patches[each.key]
  docs               = false
  examples           = false
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.control_plane_public_ipv4
  nodes                = local.control_plane_public_ipv4
}

resource "talos_machine_configuration_apply" "node" {
  for_each = local.nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.node[each.key].machine_configuration
  endpoint                    = local.public_ipv4[each.key]
  node                        = local.public_ipv4[each.key]

  # The first apply waits until the new installation has started Talos.
  timeouts = {
    create = "30m"
    update = "20m"
  }

  lifecycle {
    # A new installation erases the node, so the node needs its configuration
    # again.
    replace_triggered_by = [terraform_data.install[each.key]]

    precondition {
      condition     = contains(local.control_plane_keys, local.bootstrap_key)
      error_message = "The first control plane node \"${local.bootstrap_key}\" is no longer in control_plane_pools. Its private address is the cluster endpoint, so every node would lose the endpoint. Keep the node, or move the endpoint first: see \"The first control plane node is special\" in the README."
    }
  }

  # Upgrades run before the new configuration, as Talos recommends.
  depends_on = [
    terraform_data.install,
    # A removed control plane node leaves etcd before the other nodes drop it
    # from their firewall rules.
    terraform_data.node_removal,
    terraform_data.private_network_check,
    terraform_data.upgrade_kubernetes,
  ]
}

# A new installation of the only control plane node erases etcd. The cluster
# then needs a new bootstrap, which the module never starts by itself: with
# more control plane nodes, a second bootstrap would split etcd into two
# clusters. The README explains the manual step.
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = local.bootstrap_public_ipv4
  node                 = local.bootstrap_public_ipv4

  lifecycle {
    # A new address of the node must never start a second bootstrap.
    ignore_changes = [endpoint, node]
  }

  depends_on = [talos_machine_configuration_apply.node]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = local.bootstrap_public_ipv4
  node                 = local.bootstrap_public_ipv4

  depends_on = [talos_machine_bootstrap.this]
}

locals {
  kubernetes_client = talos_cluster_kubeconfig.this.kubernetes_client_configuration

  # The kubeconfig of Talos names the private cluster endpoint, which only
  # works inside the private network. This kubeconfig uses the public API
  # address instead.
  kubeconfig = yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [{
      name = var.cluster_name
      cluster = {
        server                     = local.kubernetes_api_url
        certificate-authority-data = local.kubernetes_client.ca_certificate
      }
    }]
    users = [{
      name = "admin@${var.cluster_name}"
      user = {
        client-certificate-data = local.kubernetes_client.client_certificate
        client-key-data         = local.kubernetes_client.client_key
      }
    }]
    contexts = [{
      name    = "admin@${var.cluster_name}"
      context = { cluster = var.cluster_name, user = "admin@${var.cluster_name}" }
    }]
    current-context = "admin@${var.cluster_name}"
  })
}
