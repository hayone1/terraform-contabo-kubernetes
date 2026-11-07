# Contabo has no DHCP, and Talos cannot read the cloud-init data of Contabo.
# Every node therefore gets its own Image Factory schematic with the network
# settings of its public interface as kernel arguments. A schematic costs
# nothing, and Talos upgrades keep the kernel arguments.
resource "talos_image_factory_schematic" "node" {
  for_each = local.nodes

  schematic = yamlencode({
    customization = merge(
      {
        extraKernelArgs = concat(
          [
            # Classic names keep the public interface at "eth0" and the
            # private interface at "eth1".
            "net.ifnames=0",
            # ip=<address>::<gateway>:<netmask>:<hostname>:<interface>:<autoconf>:<dns0>:<dns1>
            format(
              "ip=%s::%s:%s::eth0:off:%s:%s",
              local.public_ipv4_config[each.key].address,
              local.public_ipv4_config[each.key].gateway,
              local.public_ipv4_config[each.key].netmask,
              var.talos.nameservers[0],
              try(var.talos.nameservers[1], ""),
            ),
          ],
          contains(local.longhorn_keys, each.key) ? local.longhorn_v2_kernel_args : [],
          var.talos.extra_kernel_args,
        )
      },
      length(local.node_extensions[each.key]) > 0 ? {
        systemExtensions = { officialExtensions = local.node_extensions[each.key] }
      } : {},
    )
  })
}

locals {
  # Longhorn and Tailscale need their extensions only on their own nodes.
  node_extensions = {
    for key in keys(local.nodes) : key => sort(distinct(concat(
      var.talos.extensions,
      contains(local.longhorn_keys, key) ? local.longhorn_extensions : [],
      contains(local.tailscale_keys, key) ? local.tailscale_extensions : [],
    )))
  }

  # The installer image keeps the schematic, so an upgrade keeps the kernel
  # arguments and the extensions.
  installer_image = {
    for key, schematic in talos_image_factory_schematic.node :
    key => "factory.talos.dev/metal-installer/${schematic.id}:${var.talos_version}"
  }
}
