# Removes a node from the cluster before Terraform erases or cancels the
# instance: drain the node, leave etcd (control plane nodes), wipe Talos and
# power off the node, and delete the Kubernetes node object.
#
# Terraform runs the removal when a node leaves the configuration, when its
# instance is replaced, when a new reinstall generation erases the node, and
# on "terraform destroy". Set the environment variable
# TALOS_SKIP_NODE_REMOVAL=1 to skip the removal, for example for a fast
# destroy of a whole test cluster.
resource "terraform_data" "node_removal" {
  for_each = local.nodes

  # A change of the input only updates the stored value. The removal uses the
  # values of the last apply.
  input = {
    script      = local.talos_ops_script
    name        = each.value.name
    role        = each.value.role
    address     = local.public_ipv4[each.key]
    peers       = join(" ", [for key in local.control_plane_keys : local.public_ipv4[key] if key != each.key])
    api_hosts   = local.kubernetes_api_hosts
    talosconfig = data.talos_client_configuration.this.talos_config
  }

  provisioner "local-exec" {
    when = destroy
    # A refused removal (for example when etcd would lose its majority) stops
    # the apply before Terraform erases or cancels the node.
    on_failure  = fail
    quiet       = true
    interpreter = ["bash", "-c"]
    command     = "bash '${self.output.script}' remove-node"
    environment = {
      TALOSCONFIG_CONTENT = self.output.talosconfig
      NODE_NAME           = self.output.name
      NODE_ROLE           = self.output.role
      NODE_ADDRESS        = self.output.address
      PEERS               = self.output.peers
      # Values from before this setting existed have no API hosts.
      KUBERNETES_API_HOSTS = try(self.output.api_hosts, "")
    }
  }

  lifecycle {
    replace_triggered_by = [
      contabo_instance.node[each.key].id,
      contabo_instance_reinstall.node[each.key],
    ]
  }

  # The removal runs before the reinstall erases the node.
  depends_on = [contabo_instance_reinstall.node]
}
