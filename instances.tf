# The SSH key only serves the temporary Ubuntu system that installs Talos.
# Talos has no SSH server, so the key is useless once Talos runs.
resource "tls_private_key" "install" {
  algorithm = "ED25519"
}

resource "contabo_secret" "install" {
  name  = "${var.cluster_name}-talos-install"
  type  = "ssh"
  value = trimspace(tls_private_key.install.public_key_openssh)
}

resource "contabo_instance" "node" {
  for_each = local.nodes

  # Adopted instances keep their product and region. The provider reads the
  # real values from Contabo.
  existing_instance_id = each.value.existing_instance_id
  product_id           = each.value.adopted ? null : each.value.product_id
  region               = each.value.adopted ? null : var.region
  period               = each.value.adopted ? null : var.new_instance_period
  display_name         = each.value.name

  # New instances start with the temporary Ubuntu system. The installation of
  # Talos happens in terraform_data.install.
  image_id     = each.value.adopted ? null : var.installer.image_id
  ssh_keys     = each.value.adopted ? null : [tonumber(contabo_secret.install.id)]
  default_user = each.value.adopted ? null : "root"

  # A node can only join a private network with the private networking
  # add-on. New instances order the add-on together with the instance.
  # Adopted instances must already have the add-on.
  dynamic "add_ons" {
    for_each = each.value.adopted ? [] : ["1477"]
    content {
      id       = add_ons.value
      quantity = 1
    }
  }

  # New instances cost money until the end of the contract period, even after
  # Terraform cancels them.
  cancel_on_destroy = each.value.adopted ? var.adoption.cancel_on_destroy : true

  lifecycle {
    # A change of one of these settings would erase the node. Talos upgrades
    # and configuration changes never need a new installation. Contabo adds
    # add-ons by itself (for example 1501), and the module only orders add-ons
    # with a new instance.
    ignore_changes = [image_id, ssh_keys, root_password, user_data, default_user, application_id, period, license, add_ons]

    precondition {
      condition     = terraform_data.validation.output == var.cluster_name
      error_message = "The validation of the module failed."
    }

    postcondition {
      condition     = !each.value.adopted || self.region == var.region
      error_message = "The adopted instance ${coalesce(each.value.existing_instance_id, "-")} is in the region ${coalesce(self.region, "unknown")}, but the cluster is in ${var.region}. All nodes of a cluster must be in one region."
    }
    postcondition {
      condition     = self.status != "error"
      error_message = "Contabo reports an error for the instance of ${each.value.name}: ${coalesce(self.error_message, "no message")}."
    }
    postcondition {
      condition     = self.cancel_date == null || self.cancel_date == ""
      error_message = "The instance of ${each.value.name} is cancelled for ${coalesce(self.cancel_date, "-")}. A cancelled instance stops on that date, so it cannot be a node. Revoke the cancellation in the Contabo control panel."
    }
    postcondition {
      condition     = !contains(local.storage_vps_products, coalesce(self.product_id, "-"))
      error_message = "The instance of ${each.value.name} is a Storage VPS (${coalesce(self.product_id, "-")}). The Contabo API cannot install Storage VPS products."
    }
  }
}

# A random VNC password per node. Contabo cannot turn the VNC console off, and
# the console reaches the boot menu of Talos.
resource "random_password" "vnc" {
  for_each = var.vnc_passwords ? local.nodes : {}

  # Many VNC clients only read the first 8 characters.
  length  = 8
  special = false
}

resource "contabo_instance_vnc" "node" {
  for_each = var.vnc_passwords ? local.nodes : {}

  instance_id = contabo_instance.node[each.key].id
  password    = random_password.vnc[each.key].result
}

# Contabo asks for a new installation after an instance joins a private
# network. Adopted instances need one too, because the module erases them.
# Every node has this resource, so no setting can add the resource to a
# running node and erase the node.
resource "contabo_instance_reinstall" "node" {
  for_each = local.nodes

  instance_id  = contabo_instance.node[each.key].id
  image_id     = var.installer.image_id
  default_user = "root"
  ssh_keys     = [tonumber(contabo_secret.install.id)]

  # Only a new reinstall generation erases the node again. Any change of the
  # number erases the node, also a lower number or a removed entry.
  triggers = {
    reinstall_generation = tostring(each.value.reinstall_generation)
  }

  lifecycle {
    ignore_changes = [image_id, ssh_keys, default_user, root_password, user_data, application_id]
  }

  depends_on = [
    contabo_private_network.this,
    contabo_firewall.this,
  ]
}

locals {
  # The Image Factory address of the Talos kernel and initramfs of every node.
  # The schematic contains the network settings of the node, because Contabo
  # has no DHCP.
  install_image_base = {
    for key, schematic in talos_image_factory_schematic.node :
    key => "https://factory.talos.dev/image/${schematic.id}/${var.talos_version}"
  }

  # A value that changes with every installation of the node. A change runs the
  # Talos installation again.
  install_marker = { for key, reinstall in contabo_instance_reinstall.node : key => reinstall.reinstalled_at }
}

# Starts Talos from memory on the temporary Ubuntu system (kexec). Talos waits
# in maintenance mode and installs itself on the disk when
# talos_machine_configuration_apply sends the configuration.
resource "terraform_data" "install" {
  for_each = local.nodes

  triggers_replace = [local.install_marker[each.key]]

  connection {
    type        = "ssh"
    host        = local.public_ipv4[each.key]
    user        = "root"
    private_key = tls_private_key.install.private_key_openssh
    timeout     = var.installer.ssh_timeout
  }

  provisioner "file" {
    content     = file("${path.module}/scripts/install-talos.sh")
    destination = "/dev/shm/install-talos.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "bash /dev/shm/install-talos.sh '${local.install_image_base[each.key]}'",
    ]
  }

  # The Contabo firewall must protect the node before Talos starts in
  # maintenance mode.
  depends_on = [
    contabo_firewall.this,
    contabo_private_network.this,
    contabo_instance_reinstall.node,
  ]
}

