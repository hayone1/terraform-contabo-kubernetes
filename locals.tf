locals {
  pools = concat(
    [for pool in var.control_plane_pools : merge(pool, { role = "controlplane" })],
    [for pool in var.worker_pools : merge(pool, { role = "worker" })],
  )

  # One entry per node. New nodes get the keys "1", "2", ... and adopted nodes
  # keep the key from existing_instances, so removing an adopted node never
  # renames the other nodes.
  node_list = flatten([
    for pool in local.pools : concat(
      [for index in range(1, pool.count + 1) : {
        key                  = "${pool.name}-${index}"
        suffix               = tostring(index)
        pool                 = pool.name
        role                 = pool.role
        existing_instance_id = null
        product_id           = pool.product_id
      }],
      [for suffix, instance_id in pool.existing_instances : {
        key                  = "${pool.name}-${suffix}"
        suffix               = suffix
        pool                 = pool.name
        role                 = pool.role
        existing_instance_id = instance_id
        product_id           = null
      }],
    )
  ])

  # The grouping (the three dots) keeps a duplicate key from failing the plan
  # with an unclear message. A precondition below explains the problem.
  pools_by_name = { for pool in local.pools : pool.name => pool... }
  nodes_by_key  = { for node in local.node_list : node.key => node... }

  nodes = {
    for key, group in local.nodes_by_key : key => merge(group[0], {
      name                 = "${var.cluster_name}-${key}"
      adopted              = group[0].existing_instance_id != null
      labels               = local.pools_by_name[group[0].pool][0].labels
      annotations          = local.pools_by_name[group[0].pool][0].annotations
      taints               = local.pools_by_name[group[0].pool][0].taints
      config_patches       = local.pools_by_name[group[0].pool][0].config_patches
      reinstall_generation = lookup(local.pools_by_name[group[0].pool][0].reinstall_generations, group[0].suffix, 1)
    })
  }

  control_plane_keys = sort([for key, node in local.nodes : key if node.role == "controlplane"])
  worker_keys        = sort([for key, node in local.nodes : key if node.role == "worker"])

  # The first control plane node bootstraps etcd. Its private address is the
  # cluster endpoint inside the cluster. KubePrism on every node also knows
  # the other control plane nodes, so the cluster keeps working when this node
  # is down. terraform_data.bootstrap_node keeps the first choice, so a new
  # pool that sorts earlier never moves the endpoint or the bootstrap.
  bootstrap_key_candidate = try(local.control_plane_keys[0], null)
  bootstrap_key           = terraform_data.bootstrap_node.output

  # Without worker nodes, the control plane nodes run the workloads and receive
  # the public ports.
  control_plane_schedulable = length(local.worker_keys) == 0
  ingress_keys              = local.control_plane_schedulable ? local.control_plane_keys : local.worker_keys

  # Contabo product ids of Storage VPS. The Contabo API cannot order or install
  # them.
  storage_vps_products = ["V93", "V96", "V99", "V102", "V105"]

  # Instance addresses. The values are unknown until the instances exist.
  public_ipv4 = { for key, instance in contabo_instance.node : key => instance.ip_config[0].v4[0].ip }
  public_ipv4_config = {
    for key, instance in contabo_instance.node : key => {
      address = instance.ip_config[0].v4[0].ip
      gateway = instance.ip_config[0].v4[0].gateway
      netmask = cidrnetmask("0.0.0.0/${instance.ip_config[0].v4[0].netmask_cidr}")
    }
  }

  # The firewall rules of the Talos API and the Kubernetes API use these
  # ranges, together with the address of the computer that runs Terraform.
  runner_cidrs = var.admin_access.include_runner_ip ? ["${chomp(data.http.runner_ip[0].response_body)}/32"] : []
  admin_cidrs  = distinct(concat(var.admin_access.cidrs, local.runner_cidrs))
  admin_ipv4   = [for cidr in local.admin_cidrs : cidr if !strcontains(cidr, ":")]
  admin_ipv6   = [for cidr in local.admin_cidrs : cidr if strcontains(cidr, ":")]
}

data "http" "runner_ip" {
  count = var.admin_access.include_runner_ip ? 1 : 0
  url   = var.admin_access.runner_ip_url

  retry {
    attempts     = 3
    min_delay_ms = 1000
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", chomp(self.response_body)))
      error_message = "The module could not read the public IPv4 address of this computer from ${var.admin_access.runner_ip_url}. Set admin_access.cidrs and admin_access.include_runner_ip = false."
    }
  }
}

# Checks that need several variables together. A failed check stops the plan
# before Terraform orders or changes anything.
resource "terraform_data" "validation" {
  input = var.cluster_name

  lifecycle {
    precondition {
      condition     = length(local.control_plane_keys) >= 1
      error_message = "The cluster needs at least one control plane node in control_plane_pools."
    }
    precondition {
      condition = alltrue(flatten([for pool in local.pools : [
        for label in keys(pool.labels) : !can(regex("(^|\\.)(kubernetes\\.io|k8s\\.io)/", label)) || can(regex("^(node|kubelet)\\.kubernetes\\.io/", label))
      ]]))
      error_message = "Talos sets node labels with the credentials of kubelet, and Kubernetes refuses labels below kubernetes.io and k8s.io from kubelet. Use a label like \"example.com/tier\", or the prefixes node.kubernetes.io/ and kubelet.kubernetes.io/."
    }
    precondition {
      condition = alltrue(flatten([for pool in local.pools : [
        for taint in values(pool.taints) : contains(["NoSchedule", "PreferNoSchedule", "NoExecute"], element(split(":", taint), length(split(":", taint)) - 1)) && length(split(":", taint)) <= 2
      ]]))
      error_message = "A taint must map a key to \"value:Effect\" or \"Effect\". The effect is NoSchedule, PreferNoSchedule or NoExecute, for example { \"dedicated\" = \"db:NoSchedule\" }."
    }
    precondition {
      condition     = length(local.pools) == length(local.pools_by_name)
      error_message = "Every pool in control_plane_pools and worker_pools needs its own name."
    }
    precondition {
      condition     = alltrue([for pool in local.pools : can(regex("^[a-z0-9]([a-z0-9-]{0,14}[a-z0-9])?$", pool.name))])
      error_message = "A pool name must have 1 to 16 characters. It can only contain lowercase letters, digits and hyphens, and it must start and end with a letter or a digit."
    }
    precondition {
      condition = alltrue(flatten([for pool in local.pools : [
        for suffix, id in pool.existing_instances : can(regex("^[a-z0-9]([a-z0-9-]{0,6}[a-z0-9])?$", suffix)) && can(regex("^[0-9]+$", id))
      ]]))
      error_message = "Every key of existing_instances must have 1 to 8 characters (lowercase letters, digits and hyphens), and every value must be a numeric Contabo instance id, for example { \"a\" = \"200000003\" }."
    }
    precondition {
      condition     = length(local.node_list) == length(local.nodes_by_key)
      error_message = "Two nodes have the same name. A key in existing_instances must not be a number that count already uses, for example \"1\"."
    }
    precondition {
      condition     = length(distinct(flatten([for pool in local.pools : values(pool.existing_instances)]))) == length(flatten([for pool in local.pools : values(pool.existing_instances)]))
      error_message = "The same Contabo instance appears twice in existing_instances."
    }
    precondition {
      condition     = alltrue([for pool in local.pools : pool.count >= 0 && floor(pool.count) == pool.count])
      error_message = "The count of a pool must be a whole number of 0 or more."
    }
    precondition {
      condition     = alltrue([for pool in local.pools : pool.count == 0 || pool.product_id != null])
      error_message = "A pool with count > 0 needs product_id, for example \"V91\". The product decides the size and the price of every new instance."
    }
    precondition {
      condition     = alltrue([for pool in local.pools : !contains(local.storage_vps_products, coalesce(pool.product_id, "-"))])
      error_message = "Storage VPS products (V93, V96, V99, V102, V105) cannot be ordered or installed through the Contabo API. Choose a Cloud VPS or VDS product."
    }
    precondition {
      condition     = !anytrue([for node in local.node_list : node.existing_instance_id != null]) || var.adoption.allow_reinstall
      error_message = "Adopting an instance erases its disk and installs Talos. Set adoption.allow_reinstall = true if the instances in existing_instances hold nothing that you need."
    }
    precondition {
      condition     = var.private_network.existing_id == null || !anytrue([for node in local.node_list : node.existing_instance_id == null])
      error_message = "private_network.existing_id only works with adopted instances. The module never changes an existing private network, so it cannot add new instances to that network. Remove existing_id to let the module create a network."
    }
    precondition {
      condition     = var.contabo_firewall.enabled || var.installer.allow_unprotected_install
      error_message = "Without the Contabo firewall, anyone can send a configuration to a new Talos node during the first minutes and take over the node. Keep contabo_firewall.enabled = true, or set installer.allow_unprotected_install = true."
    }
    precondition {
      condition     = !var.workload_identity.enabled || var.workload_identity.azure == null || can(regex("^[0-9a-fA-F-]{36}$", var.workload_identity.azure.tenant_id))
      error_message = "workload_identity.azure.tenant_id must be the GUID of an Entra ID tenant."
    }
    precondition {
      condition     = !(var.cert_manager.enabled || var.external_dns.enabled) || var.contabo_dns_credentials != null
      error_message = "cert_manager and external_dns need contabo_dns_credentials, because both change records in Contabo DNS."
    }
    precondition {
      condition     = !var.external_dns.enabled || length(local.external_dns_domains) > 0
      error_message = "external_dns needs external_dns.domain_filters or gateway_api.domain, so that external-dns only changes the records of your domains."
    }
    precondition {
      condition     = var.gateway_api.domain == null || (var.gateway_api.enabled && var.cert_manager.enabled)
      error_message = "gateway_api.domain creates a Gateway with a certificate, so it needs gateway_api.enabled = true and cert_manager.enabled = true."
    }
    precondition {
      condition     = !local.tailscale_mode || local.tailscale_agent
      error_message = "admin_access.mode = \"tailscale\" needs tailscale.node_agent.enabled = true. The module itself reaches the Kubernetes API through the tailnet names of the control plane nodes."
    }
    precondition {
      condition     = !local.tailscale_mode || var.api_hostname == null
      error_message = "api_hostname points to the public addresses, which admin_access.mode = \"tailscale\" closes for the Kubernetes API. Remove api_hostname: the kubeconfig then uses the tailnet name of the first control plane node."
    }
    precondition {
      condition     = !(local.tailscale_agent || local.tailscale_operator) || var.tailscale.tailnet_domain != null
      error_message = "Tailscale needs tailscale.tailnet_domain, for example \"tail1234.ts.net\". The Tailscale admin console shows the domain on the DNS page."
    }
    precondition {
      condition     = !local.tailscale_agent || nonsensitive(var.tailscale_auth_key != null && var.tailscale_auth_key != "")
      error_message = "tailscale.node_agent needs tailscale_auth_key."
    }
    precondition {
      condition     = !local.tailscale_operator || nonsensitive(var.tailscale_oauth_client != null)
      error_message = "tailscale.operator needs tailscale_oauth_client."
    }
    precondition {
      condition     = !local.tailscale_operator || var.tailscale.login_server == null
      error_message = "The Tailscale operator needs OAuth clients, which only the Tailscale service offers. Turn off tailscale.operator when you use Headscale (tailscale.login_server)."
    }
    precondition {
      condition     = !local.backups_enabled || (var.backups.object_storage_id != null && var.backups.bucket != null)
      error_message = "Backups need backups.object_storage_id and backups.bucket. The bucket must already exist."
    }
    precondition {
      condition     = !local.etcd_backup || length(var.backups.etcd.age_public_keys) > 0
      error_message = "etcd backups need at least one key in backups.etcd.age_public_keys. An etcd snapshot holds every Secret of the cluster, so the module never stores it unencrypted."
    }
    precondition {
      condition     = !local.longhorn_backup || var.longhorn.enabled
      error_message = "backups.longhorn needs longhorn.enabled = true."
    }
    precondition {
      condition     = !var.longhorn.v2.enabled || var.longhorn.enabled
      error_message = "longhorn.v2 needs longhorn.enabled = true."
    }
  }
}

# Remembers the node that bootstrapped etcd. ignore_changes keeps the first
# value. See "The first control plane node is special" in the README for a
# planned move.
resource "terraform_data" "bootstrap_node" {
  input = local.bootstrap_key_candidate

  lifecycle {
    ignore_changes = [input]
  }
}
