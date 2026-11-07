locals {
  private_cidr_of_node = {
    for key in keys(local.nodes) : key => "${local.private_ipv4[key]}/${local.private_prefix_length}"
  }

  api_cert_sans = distinct(concat(
    [for key in local.control_plane_keys : local.public_ipv4[key]],
    [for key in local.control_plane_keys : local.private_ipv4[key]],
    [for key in local.control_plane_keys : local.tailnet_names[key] if contains(local.tailscale_keys, key)],
    var.api_hostname == null ? [] : [var.api_hostname],
  ))

  # Ingress rules of the Talos host firewall. Talos drops all other incoming
  # traffic on the host. Pod traffic between nodes arrives in the VXLAN
  # tunnel, which the cilium-vxlan rule allows.
  pod_subnet = var.kubernetes_network.pod_subnet

  # The Contabo firewall limits the Talos API and the Kubernetes API to
  # admin_access. The Talos firewall must not repeat that limit: after a new
  # address of the computer that runs Terraform, Terraform could no longer
  # reach a node to change its Talos firewall, while the Contabo firewall can
  # always change through the Contabo API. Both APIs need client certificates.
  # Without the Contabo firewall, the Talos firewall does the limit.
  api_sources = var.contabo_firewall.enabled ? ["0.0.0.0/0", "::/0"] : local.admin_cidrs

  # In the tailscale mode, the Kubernetes API is closed on the public
  # addresses. Tailscale in userspace mode hands the connections from the
  # tailnet to the local port of the node, and Talos does not filter local
  # connections.
  kubernetes_api_sources = local.tailscale_mode ? [] : local.api_sources

  firewall_rules_all_nodes = concat(
    [
      { name = "apid", protocol = "tcp", ports = [50000], subnets = concat(local.api_sources, local.trusted_cidrs, [local.pod_subnet]) },
      { name = "kubelet", protocol = "tcp", ports = [10250], subnets = concat(local.trusted_cidrs, [local.pod_subnet]) },
      { name = "host-dns-tcp", protocol = "tcp", ports = [53], subnets = [local.pod_subnet] },
      { name = "host-dns-udp", protocol = "udp", ports = [53], subnets = [local.pod_subnet] },
      { name = "cilium-health", protocol = "tcp", ports = [4240], subnets = local.trusted_cidrs },
      { name = "cilium-vxlan", protocol = "udp", ports = [8472], subnets = local.trusted_cidrs },
    ],
    var.cilium.wireguard ? [{ name = "cilium-wireguard", protocol = "udp", ports = [51871], subnets = local.trusted_cidrs }] : [],
    var.cilium.hubble ? [{ name = "cilium-hubble", protocol = "tcp", ports = [4244], subnets = concat(local.trusted_cidrs, [local.pod_subnet]) }] : [],
  )

  firewall_rules_control_plane = [
    { name = "trustd", protocol = "tcp", ports = [50001], subnets = local.trusted_cidrs },
    { name = "kube-apiserver", protocol = "tcp", ports = [6443], subnets = concat(local.kubernetes_api_sources, local.trusted_cidrs, [local.pod_subnet]) },
    { name = "etcd", protocol = "tcp", ports = ["2379-2380"], subnets = local.control_plane_trusted_cidrs },
  ]

  firewall_rules_public = length(local.public_ports) == 0 ? [] : [
    { name = "public", protocol = "tcp", ports = local.public_ports, subnets = ["0.0.0.0/0", "::/0"] },
  ]

  firewall_rules = {
    for key, node in local.nodes : key => concat(
      local.firewall_rules_all_nodes,
      node.role == "controlplane" ? local.firewall_rules_control_plane : [],
      contains(local.ingress_keys, key) ? local.firewall_rules_public : [],
    )
  }

  # Talos cannot delete single labels or taints whose names contain dots, so
  # the module replaces the whole KubeNodeConfig document. These are the
  # labels and taints that Talos would generate.
  role_labels = {
    controlplane = merge(
      { "node-role.kubernetes.io/control-plane" = "" },
      local.control_plane_schedulable ? {} : { "node.kubernetes.io/exclude-from-external-load-balancers" = "" },
    )
    worker = {}
  }
  role_taints = {
    controlplane = local.control_plane_schedulable ? {} : { "node-role.kubernetes.io/control-plane" = "NoSchedule" }
    worker       = {}
  }

  node_patches = {
    for key, node in local.nodes : key => concat(
      [
        yamlencode({
          machine = {
            certSANs = compact([local.public_ipv4[key], local.private_ipv4[key], lookup(local.tailnet_names, key, "")])
          }
          cluster = merge(
            # The Talos cloud controller manager initializes the nodes.
            { externalCloudProvider = { enabled = true } },
            node.role == "controlplane" ? { etcd = { advertisedSubnets = local.control_plane_trusted_cidrs } } : {},
          )
        }),
        # HostnameConfig cannot have a fixed name and automatic names at the
        # same time, so the generated document is replaced.
        yamlencode({ apiVersion = "v1alpha1", kind = "HostnameConfig", "$patch" = "delete" }),
        yamlencode({ apiVersion = "v1alpha1", kind = "HostnameConfig", hostname = node.name }),
        yamlencode({
          apiVersion  = "v1alpha1"
          kind        = "ResolverConfig"
          nameservers = [for address in var.talos.nameservers : { address = address }]
        }),
        # The private interface has no gateway. The on-link route of the
        # network is enough, because the nodes only talk to each other there.
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "LinkConfig"
          name       = var.private_network.interface
          up         = true
          addresses  = [{ address = local.private_cidr_of_node[key] }]
        }),
        yamlencode({ apiVersion = "v1alpha1", kind = "KubeNodeConfig", "$patch" = "delete" }),
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "KubeNodeConfig"
          nodeIP     = { validSubnets = local.trusted_cidrs }
          # Talos sets these labels with the credentials of kubelet. The
          # NodeRestriction admission plugin refuses labels below kubernetes.io
          # and k8s.io from kubelet, except node.kubernetes.io/ and
          # kubelet.kubernetes.io/. A validation checks the pool labels.
          labels = merge(
            local.role_labels[node.role],
            { nodepool = node.pool },
            contains(local.ingress_keys, key) ? { (local.ingress_label) = "true" } : {},
            contains(local.longhorn_keys, key) ? merge({ (local.longhorn_label) = "true" }, local.longhorn_v2_node_labels) : {},
            node.labels,
          )
          annotations = merge(contains(local.longhorn_keys, key) ? local.longhorn_v2_node_annotations : {}, node.annotations)
          taints      = local.role_taints[node.role]
        }),
        # Serving certificates of kubelet are signed by the cluster CA. The
        # Talos cloud controller manager approves the requests.
        # kubelet may not change the taints of its node later (NodeRestriction),
        # so the taints of a pool apply when the node registers.
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "KubeletConfig"
          config = {
            serverTLSBootstrap = true
            registerWithTaints = [
              for taint_key, taint in node.taints : merge(
                { key = taint_key, effect = element(split(":", taint), length(split(":", taint)) - 1) },
                length(split(":", taint)) > 1 ? { value = split(":", taint)[0] } : {},
              )
            ]
          }
        }),
        yamlencode({
          apiVersion     = "v1alpha1"
          kind           = "KubeNetworkConfig"
          podSubnets     = [var.kubernetes_network.pod_subnet]
          serviceSubnets = [var.kubernetes_network.service_subnet]
        }),
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "UnattendedInstallConfig"
          installer  = { image = local.installer_image[key] }
          provisioning = {
            diskSelector = { match = "disk.dev_path == \"${var.installer.disk}\"" }
          }
        }),
        yamlencode({ apiVersion = "v1alpha1", kind = "NetworkDefaultActionConfig", ingress = "block" }),
      ],
      [for rule in local.firewall_rules[key] : yamlencode({
        apiVersion = "v1alpha1"
        kind       = "NetworkRuleConfig"
        name       = rule.name
        # Talos wants single ports as numbers and ranges as strings. Terraform
        # turns a list with both kinds into strings, so every port is decoded
        # on its own.
        portSelector = {
          ports    = [for port in rule.ports : jsondecode(can(tonumber(port)) ? tostring(port) : jsonencode(port))]
          protocol = rule.protocol
        }
        # The Contabo firewall allows the whole private network. An existing
        # network can hold other servers, so "everybody" then excludes the
        # private network, and only the nodes (trusted_cidrs) stay allowed.
        ingress = [for subnet in distinct(rule.subnets) : merge(
          { subnet = subnet },
          subnet == "0.0.0.0/0" && var.private_network.existing_id != null ? { except = local.private_network_cidr } : {},
        )]
      })],
      contains(local.longhorn_keys, key) ? local.longhorn_volume_patches : [],
      contains(local.tailscale_keys, key) ? [local.tailscale_patches[key]] : [],
      var.talos.discovery_service ? [] : [
        yamlencode({ apiVersion = "v1alpha1", kind = "DiscoveryServiceConfig", name = "default", "$patch" = "delete" }),
      ],
      node.role == "controlplane" ? local.control_plane_patches : [],
      node.role == "controlplane" ? var.talos.control_plane_config_patches : var.talos.worker_config_patches,
      node.config_patches,
    )
  }

  control_plane_patches = concat(
    [
      # Cilium replaces kube-proxy and Flannel.
      yamlencode({ apiVersion = "v1alpha1", kind = "KubeProxyConfig", enabled = false }),
      yamlencode({ apiVersion = "v1alpha1", kind = "KubeFlannelCNIConfig", "$patch" = "delete" }),
      yamlencode({
        apiVersion    = "v1alpha1"
        kind          = "KubeAPIServerConfig"
        certExtraSANs = local.api_cert_sans
      }),
      # The Talos cloud controller manager reads node data from the Talos API,
      # and talos-backup takes etcd snapshots.
      yamlencode({
        apiVersion                  = "v1alpha1"
        kind                        = "KubeTalosAPIAccessConfig"
        allowedRoles                = concat(["os:reader"], local.etcd_backup ? ["os:etcd:backup"] : [])
        allowedKubernetesNamespaces = ["kube-system"]
      }),
    ],
    # Workload identity sets its own issuer.
    var.workload_identity.enabled ? [module.workload_identity[0].talos_config_patch] : [
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeServiceAccountConfig"
        issuer     = { issuerURL = var.service_account_issuer }
      }),
    ],
    [for manifest in local.inline_manifests : yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeInlineManifestConfig"
      name       = manifest.name
      manifest   = manifest.contents
    })],
  )
}
