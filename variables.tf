variable "cluster_name" {
  description = <<-EOT
    The name of the cluster, for example "prod".
    The module uses the name for the Talos cluster, the Kubernetes cluster, the private network, the firewall and the node names.
    The name must not change after the cluster exists, because the node names and the Talos certificates depend on the name.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$", var.cluster_name))
    error_message = "The cluster name must have 1 to 32 characters. It can only contain lowercase letters, digits and hyphens, and it must start and end with a letter or a digit."
  }
}

variable "region" {
  description = "The Contabo region of every node and of the private network, for example \"EU\". All nodes of a cluster must be in one region."
  type        = string
  default     = "EU"
  nullable    = false

  validation {
    condition     = contains(["EU", "UK", "US-central", "US-east", "US-west", "SIN", "AUS", "JPN", "IND"], var.region)
    error_message = "The region must be one of EU, UK, US-central, US-east, US-west, SIN, AUS, JPN or IND."
  }
}

variable "talos_version" {
  description = <<-EOT
    The Talos Linux version of the nodes, for example "v1.14.5".
    A new version upgrades every node in place with talosctl, one node after the other. The module needs Talos 1.14 or newer, because it uses the configuration documents of Talos 1.14.
  EOT
  type        = string
  default     = "v1.14.5"
  nullable    = false

  validation {
    condition     = can(regex("^v1\\.(1[4-9]|[2-9][0-9])\\.[0-9]+$", var.talos_version))
    error_message = "The Talos version must look like \"v1.14.5\", and it must be 1.14 or newer."
  }
}

variable "kubernetes_version" {
  description = <<-EOT
    The Kubernetes version, for example "1.36.6".
    A new version upgrades the cluster with "talosctl upgrade-k8s". Upgrade one minor version at a time, for example from 1.35 to 1.36.
  EOT
  type        = string
  default     = "1.36.6"
  nullable    = false

  validation {
    condition     = can(regex("^1\\.[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "The Kubernetes version must look like \"1.36.6\", without a \"v\" in front."
  }
}

variable "control_plane_pools" {
  description = <<-EOT
    The control plane nodes, grouped in pools. Every pool has a name, for example "cp".

    count sets the number of new instances that the module orders from Contabo. New instances need product_id, for example "V91".
    existing_instances adopts instances that you already pay for. The map goes from a short node key to the Contabo instance id, for example { "a" = "200000003" }. Adoption erases the disk of the instance (see adoption.allow_reinstall).

    A node is called "<cluster name>-<pool name>-<key>". New nodes use the keys "1", "2", "3" and so on.
    labels, annotations and taints go to the Kubernetes node. A taint maps a key to "value:Effect" or to "Effect", for example { "dedicated" = "db:NoSchedule" }.
    config_patches are extra Talos configuration patches (YAML) for the nodes of the pool.
    reinstall_generations maps a node key to a number. Raise the number of a node to erase the node and to install Talos again.
  EOT
  type = list(object({
    name                  = string
    product_id            = optional(string)
    count                 = optional(number, 0)
    existing_instances    = optional(map(string), {})
    labels                = optional(map(string), {})
    annotations           = optional(map(string), {})
    taints                = optional(map(string), {})
    config_patches        = optional(list(string), [])
    reinstall_generations = optional(map(number), {})
  }))
  nullable = false

  validation {
    condition     = sum(concat([0], [for pool in var.control_plane_pools : pool.count + length(pool.existing_instances)])) % 2 == 1
    error_message = "The cluster needs an odd number of control plane nodes, for example 1, 3 or 5. etcd needs a majority of the control plane nodes to keep working."
  }
}

variable "worker_pools" {
  description = <<-EOT
    The worker nodes, grouped in pools. The settings are the same as in control_plane_pools.
    Without worker nodes, the control plane nodes also run the workloads.
  EOT
  type = list(object({
    name                  = string
    product_id            = optional(string)
    count                 = optional(number, 0)
    existing_instances    = optional(map(string), {})
    labels                = optional(map(string), {})
    annotations           = optional(map(string), {})
    taints                = optional(map(string), {})
    config_patches        = optional(list(string), [])
    reinstall_generations = optional(map(number), {})
  }))
  default  = []
  nullable = false
}

variable "new_instance_period" {
  description = "The first contract period in months for every instance that the module orders, for example 1. Contabo bills the whole period, even when you destroy the instance earlier."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = contains([1, 3, 6, 12], var.new_instance_period)
    error_message = "The period must be 1, 3, 6 or 12 months."
  }
}

variable "adoption" {
  description = <<-EOT
    Settings for instances in existing_instances.
    allow_reinstall must be true before the module adopts an instance, because the module erases the disk of the instance and installs Talos.
    cancel_on_destroy decides whether "terraform destroy" (or the removal of the node) cancels the adopted instance. With false, Terraform does not cancel the instance, and the instance keeps costing money. The graceful node removal still wipes Talos and powers the instance off.
  EOT
  type = object({
    allow_reinstall   = optional(bool, false)
    cancel_on_destroy = optional(bool, false)
  })
  default  = {}
  nullable = false
}

variable "private_network" {
  description = <<-EOT
    The Contabo private network of the nodes. The nodes talk to each other only through the private network.

    By default, the module creates a private network for the cluster and adds every node.
    existing_id uses a private network that already exists, for example "12345". The module then never changes that network: every node must already be a member. Use this setting for adopted instances that are already in a network.
    interface is the name of the private network interface in Talos. Contabo connects the public network first ("eth0") and the private network second ("eth1").
  EOT
  type = object({
    existing_id = optional(string)
    interface   = optional(string, "eth1")
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.private_network.existing_id == null || can(regex("^[0-9]+$", var.private_network.existing_id))
    error_message = "The private_network.existing_id value must be the numeric id of a Contabo private network, for example \"12345\"."
  }
}

variable "kubernetes_network" {
  description = <<-EOT
    The address ranges inside Kubernetes. pod_subnet holds the pod addresses, and service_subnet holds the service addresses.
    The ranges must not overlap the private network of Contabo (10.0.0.0/8 networks with a /22 mask). The ranges cannot change after the cluster exists.
  EOT
  type = object({
    pod_subnet     = optional(string, "10.244.0.0/16")
    service_subnet = optional(string, "10.96.0.0/12")
  })
  default  = {}
  nullable = false

  validation {
    condition     = can(cidrhost(var.kubernetes_network.pod_subnet, 0)) && can(cidrhost(var.kubernetes_network.service_subnet, 0))
    error_message = "The pod_subnet and service_subnet values must be IPv4 ranges in CIDR form, for example \"10.244.0.0/16\"."
  }
}

variable "admin_access" {
  description = <<-EOT
    Who may reach the Talos API (port 50000) and the Kubernetes API (port 6443).

    mode "public" opens both APIs on the public addresses of the nodes, but only for cidrs.
    mode "tailscale" closes the public Kubernetes API. Admins then reach the Kubernetes API only through the tailnet (see the variable tailscale). The Talos API stays open for cidrs, because a new node can only get its first configuration through its public address. The computer that runs Terraform must be in the tailnet. For a running cluster, turn on tailscale.node_agent in one apply and the mode in a second apply, so that the nodes are in the tailnet first. api_hostname does not work in this mode.
    cidrs lists the allowed IPv4 and IPv6 ranges, for example ["203.0.113.10/32"].
    include_runner_ip adds the public IPv4 address of the computer that runs Terraform. The module reads the address from runner_ip_url. The address can change, for example after a router restart. Run "terraform apply" again after a change.
    allow_world must be true before cidrs may contain 0.0.0.0/0 or ::/0. Both APIs need client certificates, but an open port still invites attacks.
  EOT
  type = object({
    mode              = optional(string, "public")
    cidrs             = optional(list(string), [])
    include_runner_ip = optional(bool, true)
    runner_ip_url     = optional(string, "https://ipv4.icanhazip.com")
    allow_world       = optional(bool, false)
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains(["public", "tailscale"], var.admin_access.mode)
    error_message = "admin_access.mode must be \"public\" or \"tailscale\"."
  }

  validation {
    condition     = alltrue([for cidr in var.admin_access.cidrs : can(cidrhost(cidr, 0))])
    error_message = "Every entry of admin_access.cidrs must be an IPv4 or IPv6 range in CIDR form, for example \"203.0.113.10/32\"."
  }

  validation {
    condition     = length(var.admin_access.cidrs) > 0 || var.admin_access.include_runner_ip
    error_message = "Nobody could reach the cluster: set admin_access.cidrs, or keep admin_access.include_runner_ip = true."
  }

  validation {
    condition = var.admin_access.allow_world || alltrue([
      for cidr in var.admin_access.cidrs : !contains(["0.0.0.0/0", "::/0"], cidr)
    ])
    error_message = "admin_access.cidrs opens the Talos API and the Kubernetes API to the whole internet. Set admin_access.allow_world = true if you really want that."
  }
}

variable "public_ports" {
  description = <<-EOT
    TCP ports that the whole internet may reach on the ingress nodes, for example [80, 443] for an ingress controller with host ports.
    The ingress nodes are the worker nodes, or the control plane nodes when the cluster has no worker nodes. The module opens the ports in the Talos host firewall and in the Contabo firewall.
  EOT
  type        = list(number)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for port in var.public_ports : port >= 1 && port <= 65535 && floor(port) == port && !contains([50000, 50001, 6443, 2379, 2380, 10250], port)])
    error_message = "Every public port must be a whole number from 1 to 65535. The ports 50000, 50001, 6443, 2379, 2380 and 10250 belong to Talos and Kubernetes and cannot be public."
  }
}

variable "contabo_firewall" {
  description = <<-EOT
    The Contabo firewall in front of the nodes. The Talos host firewall always protects the nodes too.

    The Contabo firewall also protects the installation. Talos starts without any protection until the module sends the configuration, so the module attaches the firewall before Talos starts.
    extra_inbound_rules adds rules, for example for a NodePort service. protocol is "tcp", "udp", "icmp" or "any". An empty ports list means every port.
  EOT
  type = object({
    enabled = optional(bool, true)
    extra_inbound_rules = optional(list(object({
      name       = string
      protocol   = string
      ports      = optional(list(string), [])
      ipv4_cidrs = optional(list(string), [])
      ipv6_cidrs = optional(list(string), [])
    })), [])
  })
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for rule in var.contabo_firewall.extra_inbound_rules : contains(["tcp", "udp", "icmp", "any"], rule.protocol)])
    error_message = "The protocol of every extra inbound rule must be \"tcp\", \"udp\", \"icmp\" or \"any\"."
  }
}

variable "installer" {
  description = <<-EOT
    How the module installs Talos on a Contabo instance.

    Contabo cannot boot Talos from a URL. The module therefore installs a standard Ubuntu image with an SSH key, connects with SSH and starts Talos from memory with kexec. Talos then installs itself on disk.
    image_id is the Contabo image of that temporary system. The default is Ubuntu 24.04.
    disk is the disk of the instance. Contabo instances use "/dev/sda".
    ssh_timeout is how long Terraform waits for the temporary system. Contabo reports a reinstall as done before the instance boots, and one reinstall in the live tests took 16 minutes.
    allow_unprotected_install must be true when contabo_firewall.enabled is false. Talos accepts a configuration from anyone during the first minutes after the installation, so a node without the Contabo firewall can be taken over during this time.
  EOT
  type = object({
    image_id                  = optional(string, "d64d5c6c-9dda-4e38-8174-0ee282474d8a")
    disk                      = optional(string, "/dev/sda")
    ssh_timeout               = optional(string, "30m")
    allow_unprotected_install = optional(bool, false)
  })
  default  = {}
  nullable = false

  validation {
    condition     = can(regex("^/dev/[a-z0-9]+$", var.installer.disk))
    error_message = "The installer.disk value must be a whole disk, for example \"/dev/sda\"."
  }
}

variable "talos" {
  description = <<-EOT
    Settings of the Talos image and the Talos configuration.

    extensions lists official Talos system extensions, for example ["siderolabs/iscsi-tools"].
    extra_kernel_args adds kernel arguments. The module already sets the network arguments, because Contabo has no DHCP.
    nameservers are the DNS servers of the nodes. They must be IPv4 addresses.
    discovery_service enables the Talos discovery service, which helps the nodes to find each other.
    control_plane_config_patches and worker_config_patches are extra Talos configuration patches (YAML) for all control plane nodes or all worker nodes.
  EOT
  type = object({
    extensions                   = optional(list(string), [])
    extra_kernel_args            = optional(list(string), [])
    nameservers                  = optional(list(string), ["1.1.1.1", "8.8.8.8"])
    discovery_service            = optional(bool, true)
    control_plane_config_patches = optional(list(string), [])
    worker_config_patches        = optional(list(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition     = length(var.talos.nameservers) >= 1 && alltrue([for ip in var.talos.nameservers : can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", ip))])
    error_message = "talos.nameservers needs at least one IPv4 address, for example [\"1.1.1.1\", \"8.8.8.8\"]."
  }
}

variable "api_hostname" {
  description = <<-EOT
    An optional DNS name for the Kubernetes API, for example "k8s.example.com".
    The module adds the name to the certificates of the API server and uses the name in the kubeconfig output. You create the DNS records yourself. Point the name to the public addresses of the control plane nodes.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.api_hostname == null || can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", coalesce(var.api_hostname, "-")))
    error_message = "The api_hostname value must be a DNS name like \"k8s.example.com\"."
  }
}

variable "service_account_issuer" {
  description = <<-EOT
    The issuer that Kubernetes writes into service account tokens when workload identity is off.
    The default does not depend on any node address, so a replaced control plane node does not invalidate the tokens. Workload identity replaces this value with a public address.
  EOT
  type        = string
  default     = "https://kubernetes.default.svc.cluster.local"
  nullable    = false

  validation {
    condition     = can(regex("^https://[^/?#]+(/[^?#]*[^/?#])?$", var.service_account_issuer))
    error_message = "The service account issuer must start with https://, and it must not have a query, a fragment or a slash at the end."
  }
}

variable "cilium" {
  description = <<-EOT
    Settings of Cilium, the network plugin of the cluster.
    wireguard encrypts the traffic between the nodes. hubble enables the Hubble network observer without its user interface.
    helm_values are merged over the values of the module.
  EOT
  type = object({
    chart_version = optional(string, "1.20.4")
    wireguard     = optional(bool, true)
    hubble        = optional(bool, false)
    helm_values   = optional(any, {})
  })
  default  = {}
  nullable = false
}

variable "talos_ccm" {
  description = <<-EOT
    Settings of the Talos cloud controller manager. The controller sets the addresses of the nodes, and the controller approves the serving certificates of kubelet. kubectl logs and metrics-server need those certificates.
  EOT
  type = object({
    chart_version = optional(string, "0.5.8")
    helm_values   = optional(any, {})
  })
  default  = {}
  nullable = false
}

variable "metrics_server" {
  description = "Settings of metrics-server, which provides \"kubectl top\" and the data for the horizontal pod autoscaler."
  type = object({
    enabled       = optional(bool, true)
    chart_version = optional(string, "3.14.0")
    helm_values   = optional(any, {})
  })
  default  = {}
  nullable = false
}

variable "extra_manifests" {
  description = <<-EOT
    Extra Kubernetes manifests that Talos applies, as a map from a name to the YAML text, for example { "namespaces" = file("namespaces.yaml") }.
    The manifests become part of the control plane configuration, so do not put secrets into them unless you protect the Terraform state.
  EOT
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "workload_identity" {
  description = <<-EOT
    Workload identity lets pods log in to cloud providers, such as Microsoft Entra ID, with their service account token instead of a password.
    The settings go to the module modules/workload-identity. Read the README of that module first, because the issuer must never change after the cluster exists.

    issuer is the same object as the "issuer" input of modules/workload-identity, for example { object_storage = { object_storage_id = "00000000-..." } }.
    azure enables the Azure workload identity webhook. Set tenant_id to the Entra ID tenant.
  EOT
  type = object({
    enabled = optional(bool, false)
    issuer = optional(object({
      mode = optional(string, "object_storage")
      object_storage = optional(object({
        object_storage_id     = string
        bucket_name           = optional(string)
        create_bucket         = optional(bool, true)
        cache_max_age_seconds = optional(number, 60)
      }))
      external_url = optional(string)
    }))
    issuer_generation           = optional(number, 1)
    additional_accepted_issuers = optional(list(string), [])
    azure = optional(object({
      tenant_id             = string
      webhook_chart_version = optional(string, "1.6.1")
      webhook_namespace     = optional(string, "azure-workload-identity-system")
      webhook_helm_values   = optional(any, {})
    }))
  })
  default  = {}
  nullable = false

  validation {
    condition     = !var.workload_identity.enabled || var.workload_identity.issuer != null
    error_message = "Workload identity needs workload_identity.issuer."
  }
}

variable "vnc_passwords" {
  description = <<-EOT
    Whether the module sets a random VNC password on every node. Contabo cannot turn the VNC console off, and the console reaches the boot menu of Talos, which can reset the node.
    The passwords are in the Terraform state and in the sensitive vnc output.
  EOT
  type        = bool
  default     = true
  nullable    = false
}

variable "longhorn" {
  description = <<-EOT
    Longhorn, a replicated block storage for persistent volumes. Contabo has no cloud volumes, so Longhorn keeps the data on the disks of the nodes.
    Longhorn runs on the worker nodes, or on the control plane nodes when the cluster has no worker nodes. On those nodes, the module limits the Talos EPHEMERAL volume (container images, logs and pod data) to ephemeral_max_size, for example "50GiB", and gives the rest of the disk to Longhorn. min_size is the smallest Longhorn part that Talos accepts.
    Talos reads the disk layout only from the first configuration of a node. To turn Longhorn on for a running node, install the node again (raise its reinstall generation).
    The first worker pool moves Longhorn away from the control plane nodes: they lose the Longhorn extensions and their Longhorn disk. Move the volumes to the workers first, or plan with workers from the start.
    replica_count is the number of copies of every volume. The default is 3, or the number of Longhorn nodes when the cluster has fewer.
    default_storage_class makes the storage class "longhorn" the default storage class of the cluster.
    v2 turns on the V2 Data Engine of Longhorn and the storage class "longhorn-v2". The V2 Data Engine is a technical preview of Longhorn. The engine keeps its volumes on a raw partition (a disk part without a file system) of the size in size, for example "50GiB", on every Longhorn node. The engine also reserves 2 GiB of memory as hugepages and keeps 2 CPU cores of every Longhorn node busy. interrupt_mode lets the engine wait for work instead of keeping the cores busy, which costs some speed. Longhorn changes the mode only while no v2 volume is attached. Like the disk layout, the raw partition only comes with the first configuration of a node, so turn v2 on before the nodes start, or install the nodes again. To turn v2 off, delete every v2 volume first, because a v2 volume stops working without the engine.
  EOT
  type = object({
    enabled               = optional(bool, false)
    chart_version         = optional(string, "1.13.0")
    ephemeral_max_size    = optional(string, "50GiB")
    min_size              = optional(string, "10GiB")
    replica_count         = optional(number)
    default_storage_class = optional(bool, true)
    helm_values           = optional(any, {})
    v2 = optional(object({
      enabled        = optional(bool, false)
      size           = optional(string, "50GiB")
      interrupt_mode = optional(bool, false)
    }), {})
  })
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for size in [var.longhorn.ephemeral_max_size, var.longhorn.min_size, var.longhorn.v2.size] : can(regex("^[1-9][0-9]*(MiB|GiB|TiB|MB|GB|TB)$", size))])
    error_message = "ephemeral_max_size, min_size and v2.size must be sizes like \"50GiB\" or \"500MiB\"."
  }
  validation {
    condition     = var.longhorn.replica_count == null || try(var.longhorn.replica_count >= 1 && floor(var.longhorn.replica_count) == var.longhorn.replica_count, false)
    error_message = "longhorn.replica_count must be a whole number of 1 or more."
  }
}

variable "gateway_api" {
  description = <<-EOT
    The Gateway API of Cilium, the ingress of the cluster. Contabo has no load balancer, so Envoy of Cilium listens on the ports 80 and 443 of the ingress nodes (host network mode). The module opens both ports on the ingress nodes.
    crds_version is the version of the Gateway API CRDs (standard channel) that the module installs.
    With domain, for example "apps.example.com", and cert_manager, the module also creates the Gateway "public" in the namespace "gateway". The Gateway has HTTP and HTTPS listeners for the domain and every name below the domain, and cert-manager gets a wildcard certificate for them from certificate_issuer. Routes from every namespace can use the Gateway.
  EOT
  type = object({
    enabled            = optional(bool, false)
    crds_version       = optional(string, "v1.6.3")
    domain             = optional(string)
    certificate_issuer = optional(string, "letsencrypt-production")
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.gateway_api.domain == null || can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", coalesce(var.gateway_api.domain, "-")))
    error_message = "gateway_api.domain must be a DNS name like \"apps.example.com\", without \"*\" and without a dot at the end."
  }
  validation {
    condition     = contains(["letsencrypt-staging", "letsencrypt-production"], var.gateway_api.certificate_issuer)
    error_message = "gateway_api.certificate_issuer must be \"letsencrypt-staging\" or \"letsencrypt-production\"."
  }
}

variable "contabo_dns_credentials" {
  description = <<-EOT
    Contabo API credentials for cert-manager and external-dns: client_id, client_secret, api_user and api_password. The module stores them in the Secret "contabo-credentials" in the namespaces cert-manager and external-dns.
    The Secret is an inline manifest, so the credentials are also in the Talos configuration of the control plane nodes and in the Terraform state. Use a Contabo user whose role allows only the DNS API, because the credentials of your main user can cancel every server.
  EOT
  type = object({
    client_id     = string
    client_secret = string
    api_user      = string
    api_password  = string
  })
  default   = null
  sensitive = true
}

variable "cert_manager" {
  description = <<-EOT
    cert-manager with the Contabo DNS webhook. The module creates the ClusterIssuers "letsencrypt-staging" and "letsencrypt-production", which prove the ownership of a domain with DNS records in Contabo DNS (DNS-01). The domain must use the Contabo name servers.
    acme_email is the address where Let's Encrypt writes before a certificate expires.
  EOT
  type = object({
    enabled               = optional(bool, false)
    chart_version         = optional(string, "v1.21.3")
    webhook_chart_version = optional(string, "0.1.1")
    acme_email            = optional(string)
    helm_values           = optional(any, {})
    webhook_helm_values   = optional(any, {})
  })
  default  = {}
  nullable = false

  validation {
    condition     = !var.cert_manager.enabled || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", coalesce(var.cert_manager.acme_email, "-")))
    error_message = "cert_manager needs acme_email, an email address like \"admin@example.com\"."
  }
}

variable "external_dns" {
  description = <<-EOT
    external-dns with the Contabo DNS webhook. external-dns creates DNS records for HTTPRoutes and LoadBalancer services in Contabo DNS.
    domain_filters limits external-dns to these domains. The default is gateway_api.domain.
    policy "sync" also deletes records that external-dns created before. "upsert-only" never deletes records.
    sources are the Kubernetes objects that external-dns reads.
  EOT
  type = object({
    enabled         = optional(bool, false)
    chart_version   = optional(string, "1.23.0")
    webhook_version = optional(string, "0.1.0")
    domain_filters  = optional(list(string))
    policy          = optional(string, "sync")
    sources         = optional(list(string), ["gateway-httproute", "service"])
    helm_values     = optional(any, {})
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains(["sync", "upsert-only"], var.external_dns.policy)
    error_message = "external_dns.policy must be \"sync\" or \"upsert-only\"."
  }
}

variable "tailscale" {
  description = <<-EOT
    Tailscale gives admins a private path to the cluster through a tailnet, a private network of Tailscale. The module never routes cluster traffic through Tailscale.

    tailnet_domain is the MagicDNS domain of the tailnet, for example "tail1234.ts.net". The Tailscale admin console shows the domain on the DNS page.
    login_server is the address of a Headscale server, for example "https://headscale.example.com". Leave it unset (null) for the Tailscale service. Headscale is a control server for Tailscale clients that you run yourself. With Headscale, tailnet_domain is the base_domain of the Headscale configuration. The node agent normally logs in only once and then keeps its login in a state folder on the node. Every login server gets its own state folder, so a node that moves to another login server logs in again with the new auth key.
    admin_sources are the users, groups or tags that the grants of the output tailscale_policy let in, for example ["group:k8s-admins"]. The default is every admin of the tailnet.
    tag_owners are the users or groups that may use the node and operator tags in the output tailscale_policy. The default is every admin of the tailnet. Headscale has no "autogroup:admin", so set admin_sources and tag_owners to Headscale users, groups or tags there, for example ["admin@"].

    node_agent runs Tailscale on the control plane nodes (and on the workers with workers = true). Every node joins the tailnet as "<node name>.<tailnet_domain>" with the tags in tags. The node agent needs tailscale_auth_key. The Talos API and the Kubernetes API of a node answer on its tailnet name, and the module adds the names to the certificates. Tailscale runs in userspace mode: it creates no network interface and changes no route. Tailscale hands every tailnet connection to the local port of the node, so the tailnet policy is the only filter: give the node tags no other grants than the grants of the output tailscale_policy.

    operator installs the Tailscale Kubernetes operator with its API server proxy. Admins then run "tailscale configure kubeconfig <hostname>" and log in to Kubernetes with their Tailscale identity. The operator needs tailscale_oauth_client and the Tailscale service (no Headscale). hostname defaults to "<cluster name>-k8s". cluster_role_bindings maps a Kubernetes group to a ClusterRole, for example { "tailnet:cluster-admins" = "cluster-admin" }. A grant in the tailnet policy decides which Tailscale users get which group (see the output tailscale_policy).
  EOT
  type = object({
    tailnet_domain = optional(string)
    login_server   = optional(string)
    admin_sources  = optional(list(string), ["autogroup:admin"])
    tag_owners     = optional(list(string), ["autogroup:admin"])
    node_agent = optional(object({
      enabled    = optional(bool, false)
      workers    = optional(bool, false)
      tags       = optional(list(string), ["tag:k8s-node"])
      extra_args = optional(list(string), [])
    }), {})
    operator = optional(object({
      enabled               = optional(bool, false)
      chart_version         = optional(string, "1.104.4")
      hostname              = optional(string)
      tags                  = optional(list(string), ["tag:k8s-operator"])
      proxy_tags            = optional(list(string), ["tag:k8s"])
      cluster_role_bindings = optional(map(string), { "tailnet:cluster-admins" = "cluster-admin" })
      helm_values           = optional(any, {})
    }), {})
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.tailscale.tailnet_domain == null || can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", coalesce(var.tailscale.tailnet_domain, "-")))
    error_message = "tailscale.tailnet_domain must be a DNS name like \"tail1234.ts.net\", without a dot at the end."
  }
  validation {
    condition     = var.tailscale.login_server == null || can(regex("^https?://[a-z0-9.-]+(:[0-9]+)?/?$", coalesce(var.tailscale.login_server, "-")))
    error_message = "tailscale.login_server must be the address of a Headscale server, for example \"https://headscale.example.com\" or \"https://headscale.example.com:8443\"."
  }
  validation {
    condition = alltrue([
      for tag in concat(var.tailscale.node_agent.tags, var.tailscale.operator.tags, var.tailscale.operator.proxy_tags) :
      can(regex("^tag:[a-zA-Z0-9-]+$", tag))
    ])
    error_message = "Every Tailscale tag must look like \"tag:k8s-node\"."
  }
  validation {
    condition     = var.tailscale.operator.hostname == null || can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", coalesce(var.tailscale.operator.hostname, "-")))
    error_message = "tailscale.operator.hostname must be one DNS label, for example \"prod-k8s\"."
  }
}

variable "tailscale_auth_key" {
  description = <<-EOT
    The Tailscale auth key of the node agent. The key must carry the tags of tailscale.node_agent.tags, and it must be reusable, because every node uses the same key.
    An auth key expires after 90 days at most, and a new node needs a valid key. The secret of an OAuth client never expires: use "<client secret>?ephemeral=false&preauthorized=true" with a client that has the scope auth_keys and the node tags.
    The key is in the Terraform state and in the Talos configuration of the nodes.
  EOT
  type        = string
  default     = null
  sensitive   = true
}

variable "tailscale_oauth_client" {
  description = <<-EOT
    The OAuth client of the Tailscale operator: client_id and client_secret. The client needs write access to the scopes devices:core, auth_keys and services, all with the tag of tailscale.operator.tags.
    The secret is in the Terraform state and in the Talos configuration of the control plane nodes.
  EOT
  type = object({
    client_id     = string
    client_secret = string
  })
  default   = null
  sensitive = true
}

variable "backups" {
  description = <<-EOT
    Backups of etcd and of the Longhorn volumes to a bucket in a Contabo object storage.

    object_storage_id is the Contabo object storage, for example "00000000-0000-0000-0000-000000000000". bucket is a bucket that already exists in the object storage, for example "prod-backups". The module never creates or deletes the bucket, so a "terraform destroy" keeps the backups. s3_region is the region name for S3 clients. The default comes from the S3 address of the object storage, for example "eu2".

    etcd saves an etcd snapshot on every schedule (a cron expression in UTC) with talos-backup. talos-backup encrypts every snapshot with age for age_public_keys, for example ["age1..."]. Keep the private key outside the cluster: without the key, nobody can read the snapshots.
    longhorn makes the bucket the backup target of Longhorn and backs up every volume on the schedule. retain is the number of backups that Longhorn keeps of every volume.
    The bucket needs a lifecycle rule or a manual cleanup for old etcd snapshots, because talos-backup never deletes snapshots.
  EOT
  type = object({
    object_storage_id = optional(string)
    bucket            = optional(string)
    s3_region         = optional(string)
    etcd = optional(object({
      enabled         = optional(bool, false)
      schedule        = optional(string, "0 */6 * * *")
      age_public_keys = optional(list(string), [])
      image           = optional(string, "ghcr.io/siderolabs/talos-backup:v0.1.0")
    }), {})
    longhorn = optional(object({
      enabled  = optional(bool, false)
      schedule = optional(string, "0 3 * * *")
      retain   = optional(number, 7)
    }), {})
  })
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for key in var.backups.etcd.age_public_keys : can(regex("^age1[0-9a-z]{58}$", key))])
    error_message = "Every entry of backups.etcd.age_public_keys must be an age public key like \"age1...\" (62 characters)."
  }
  validation {
    condition     = alltrue([for schedule in [var.backups.etcd.schedule, var.backups.longhorn.schedule] : length(split(" ", trimspace(schedule))) == 5])
    error_message = "The backup schedules must be cron expressions with 5 fields, for example \"0 3 * * *\"."
  }
  validation {
    condition     = var.backups.longhorn.retain >= 1 && floor(var.backups.longhorn.retain) == var.backups.longhorn.retain
    error_message = "backups.longhorn.retain must be a whole number of 1 or more."
  }
  validation {
    condition     = var.backups.bucket == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", coalesce(var.backups.bucket, "-")))
    error_message = "backups.bucket must be a valid bucket name, for example \"prod-backups\"."
  }
}

variable "backup_s3_credentials" {
  description = <<-EOT
    The S3 access key and secret key for the backups: access_key and secret_key.
    Without this value, the module reads the S3 credentials of the Contabo API user for the object storage. Those credentials open every bucket of the object storage, so the cluster could read and delete all buckets there. Pass other credentials if other data lives in the object storage.
    The keys are in the Terraform state and in the Talos configuration of the control plane nodes.
  EOT
  type = object({
    access_key = string
    secret_key = string
  })
  default   = null
  sensitive = true
}
