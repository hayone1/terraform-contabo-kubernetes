# Talos and Kubernetes upgrades. The order follows the Talos documentation:
# first Talos on every node, then Kubernetes, then the new configuration.
# The steps need bash and talosctl on the computer that runs Terraform. The
# Talos upgrade also uses kubectl when kubectl is installed.

locals {
  talos_ops_script = "${path.module}/scripts/talos-ops.sh"

  # The talosconfig is passed to the script and never written into the
  # Terraform output. nonsensitive() only lets Terraform show the output of
  # the script, which never prints the talosconfig.
  talos_ops_environment = {
    TALOSCONFIG_CONTENT = nonsensitive(data.talos_client_configuration.this.talos_config)
    BOOTSTRAP_NODE      = local.bootstrap_public_ipv4
    CONTROL_PLANE_NODES = join(",", local.control_plane_private_ipv4)
    WORKER_NODES        = join(",", local.worker_private_ipv4)
    KUBERNETES_API_URL  = local.kubernetes_api_url
    KUBERNETES_VERSION  = var.kubernetes_version
    TALOS_VERSION       = var.talos_version
    NODE_ADDRESSES = join("\n", [
      for key in concat(local.control_plane_keys, local.worker_keys) :
      "${local.nodes[key].role} ${local.public_ipv4[key]} ${local.private_ipv4[key]}"
    ])
    KUBERNETES_API_HOSTS = local.kubernetes_api_hosts
  }

  # One line per control plane node: "<public address> <Kubernetes API host>".
  # In the tailscale mode, the host is the tailnet name of the node.
  kubernetes_api_hosts = join("\n", [
    for key in local.control_plane_keys : "${local.public_ipv4[key]} ${local.kubernetes_api_host_of[key]}"
  ])

  # Control plane nodes first, then the workers, each group in name order.
  upgrade_order = concat(local.control_plane_keys, local.worker_keys)

  # The ExtensionServiceConfig documents of every node, one line per node:
  # "<public address> <documents in base64>". A new extension that needs a
  # configuration (for example Tailscale) keeps the boot of Talos waiting until
  # its configuration exists. The upgrade therefore sends these documents to
  # the node before the node restarts with the new extension.
  extension_service_configs = join("\n", compact([
    for key in local.upgrade_order : (
      length(local.extension_service_documents[key]) == 0 ? "" :
      "${local.public_ipv4[key]} ${base64encode(join("\n---\n", local.extension_service_documents[key]))}"
    )
  ]))
  extension_service_documents = {
    for key in local.upgrade_order : key => [
      for document in flatten([for patch in local.node_patches[key] : split("\n---\n", patch)]) :
      document if try(yamldecode(document).kind, "") == "ExtensionServiceConfig"
    ]
  }
}

resource "terraform_data" "upgrade_talos" {
  triggers_replace = [
    var.talos_version,
    sha256(join(",", [for key in local.upgrade_order : talos_image_factory_schematic.node[key].id])),
  ]

  provisioner "local-exec" {
    quiet       = true
    interpreter = ["bash", "-c"]
    command     = "bash '${local.talos_ops_script}' upgrade-talos"
    environment = merge(local.talos_ops_environment, {
      NODES = join("\n", [
        for key in local.upgrade_order :
        "${local.public_ipv4[key]} ${local.installer_image[key]} ${talos_image_factory_schematic.node[key].id} ${local.nodes[key].name}"
      ])
      # The script never prints these documents. nonsensitive() only lets
      # Terraform show the output of the script.
      EXTENSION_SERVICE_CONFIGS = nonsensitive(local.extension_service_configs)
    })
  }

  depends_on = [terraform_data.install]
}

resource "terraform_data" "upgrade_kubernetes" {
  triggers_replace = [var.kubernetes_version]

  provisioner "local-exec" {
    quiet       = true
    interpreter = ["bash", "-c"]
    command     = "bash '${local.talos_ops_script}' upgrade-kubernetes"
    environment = local.talos_ops_environment
  }

  depends_on = [terraform_data.upgrade_talos]
}

# Talos stores changed inline manifests but does not apply them.
# "talosctl upgrade-k8s" to the current version applies them. The step also
# waits until the cluster is healthy, also after the first bootstrap.
resource "terraform_data" "sync_kubernetes" {
  triggers_replace = [
    local.inline_manifests_sha256,
    var.kubernetes_version,
    talos_machine_bootstrap.this.id,
    # A new or reinstalled node also waits for a healthy cluster.
    sha256(join(",", [for key in sort(keys(terraform_data.install)) : terraform_data.install[key].id])),
  ]

  provisioner "local-exec" {
    quiet       = true
    interpreter = ["bash", "-c"]
    command     = "bash '${local.talos_ops_script}' sync-kubernetes"
    environment = local.talos_ops_environment
  }

  depends_on = [
    talos_machine_configuration_apply.node,
    talos_cluster_kubeconfig.this,
  ]
}
