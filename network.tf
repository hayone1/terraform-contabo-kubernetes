resource "contabo_private_network" "this" {
  count = var.private_network.existing_id == null ? 1 : 0

  name        = var.cluster_name
  description = "Private network of the Kubernetes cluster ${var.cluster_name}"
  region      = var.region

  # The provider orders the private networking add-on for every instance that
  # does not have it yet, and then adds the instance to the network.
  instance_ids = [for key in sort(keys(local.nodes)) : tonumber(contabo_instance.node[key].id)]
}

data "contabo_private_network" "existing" {
  count = var.private_network.existing_id == null ? 0 : 1
  id    = var.private_network.existing_id
}

locals {
  private_network_id   = var.private_network.existing_id == null ? contabo_private_network.this[0].id : data.contabo_private_network.existing[0].id
  private_network_cidr = var.private_network.existing_id == null ? contabo_private_network.this[0].cidr : data.contabo_private_network.existing[0].cidr
  private_network_members = (
    var.private_network.existing_id == null
    ? [for member in contabo_private_network.this[0].instances : { id = tostring(member.instance_id), config = member.private_ip_config }]
    : [for member in data.contabo_private_network.existing[0].instances : { id = tostring(member.instance_id), config = member.private_ip_config }]
  )
  private_ipv4_by_instance = {
    for member in local.private_network_members : member.id => try(member.config[0].v4[0].ip, null)
  }
  private_ipv4 = {
    for key, instance in contabo_instance.node : key => lookup(local.private_ipv4_by_instance, tostring(instance.id), null)
  }
  private_prefix_length = split("/", local.private_network_cidr)[1]

  # The nodes trust each other through these ranges. A network that the module
  # created only holds cluster nodes. An existing network can hold other
  # servers, so the module then only trusts the addresses of the nodes.
  trusted_cidrs = (
    var.private_network.existing_id == null
    ? [local.private_network_cidr]
    : [for key in sort(keys(local.nodes)) : "${local.private_ipv4[key]}/32"]
  )
  control_plane_trusted_cidrs = (
    var.private_network.existing_id == null
    ? [local.private_network_cidr]
    : [for key in local.control_plane_keys : "${local.private_ipv4[key]}/32"]
  )
}

# The Contabo firewall filters the public traffic before it reaches the node.
# The Talos host firewall (talos_firewall.tf) filters again on every node.
resource "contabo_firewall" "this" {
  count = var.contabo_firewall.enabled ? 1 : 0

  name         = var.cluster_name
  description  = "Kubernetes cluster ${var.cluster_name}, managed by Terraform"
  status       = "active"
  instance_ids = [for key in sort(keys(local.nodes)) : tonumber(contabo_instance.node[key].id)]

  rules {
    # SSH only serves the temporary installation system. Talos has no SSH
    # server. In the tailscale mode, the Kubernetes API is only reachable
    # through the tailnet.
    inbound {
      display_name = "admin"
      protocol     = "tcp"
      dest_ports   = local.tailscale_mode ? ["22", "50000"] : ["22", "6443", "50000"]
      src_cidr {
        ipv4 = local.admin_ipv4
        ipv6 = local.admin_ipv6
      }
    }

    # It is unknown whether the Contabo firewall also filters the private
    # network, so the private network is always allowed.
    inbound {
      display_name = "private-network"
      protocol     = "any"
      src_cidr {
        ipv4 = [local.private_network_cidr]
      }
    }

    inbound {
      display_name = "icmp"
      protocol     = "icmp"
      src_cidr {
        ipv4 = ["0.0.0.0/0"]
        ipv6 = ["::/0"]
      }
    }

    dynamic "inbound" {
      for_each = length(local.public_ports) > 0 ? [1] : []
      content {
        display_name = "public"
        protocol     = "tcp"
        dest_ports   = [for port in local.public_ports : tostring(port)]
        src_cidr {
          ipv4 = ["0.0.0.0/0"]
          ipv6 = ["::/0"]
        }
      }
    }

    dynamic "inbound" {
      for_each = var.contabo_firewall.extra_inbound_rules
      content {
        display_name = inbound.value.name
        protocol     = inbound.value.protocol
        dest_ports   = inbound.value.ports
        src_cidr {
          ipv4 = inbound.value.ipv4_cidrs
          ipv6 = inbound.value.ipv6_cidrs
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.admin_cidrs) > 0
      error_message = "The firewall needs at least one admin address. Set admin_access.cidrs or admin_access.include_runner_ip = true."
    }
  }
}

# Every node must have a private address before Talos gets its configuration.
resource "terraform_data" "private_network_check" {
  input = local.private_network_id

  lifecycle {
    precondition {
      condition     = alltrue([for key in keys(local.nodes) : local.private_ipv4[key] != null])
      error_message = "These nodes have no address in the private network ${local.private_network_id}: ${join(", ", [for key in sort(keys(local.nodes)) : "${local.nodes[key].name} (instance ${contabo_instance.node[key].id})" if local.private_ipv4[key] == null])}. With private_network.existing_id, add the instances to the network in the Contabo control panel first."
    }
  }
}
