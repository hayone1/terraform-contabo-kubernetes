# The module renders the charts with Helm and gives the manifests to Talos as
# inline manifests. Talos applies them at bootstrap, and the sync step
# (operations.tf) applies changes later. No chart needs the cluster at plan
# time.

locals {
  node_count = length(local.nodes)

  cilium_values = {
    ipam                 = { mode = "kubernetes" }
    kubeProxyReplacement = true
    # KubePrism on every node forwards to all control plane nodes.
    k8sServiceHost = "localhost"
    k8sServicePort = 7445
    # The tunnel works on every network. Whether the Contabo private network
    # carries routed pod traffic between nodes is not known.
    routingMode    = "tunnel"
    tunnelProtocol = "vxlan"
    # Talos settings from the Talos documentation: Talos mounts the cgroup
    # file system itself and does not allow SYS_MODULE.
    cgroup = {
      autoMount = { enabled = false }
      hostRoot  = "/sys/fs/cgroup"
    }
    securityContext = {
      capabilities = {
        ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
        cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
      }
    }
    encryption = var.cilium.wireguard ? { enabled = true, type = "wireguard" } : { enabled = false, type = "wireguard" }
    # LoadBalancer services get the public addresses of the nodes, because
    # Contabo has no load balancer.
    nodeIPAM             = { enabled = true }
    defaultLBServiceIPAM = "nodeipam"
    # A changed configuration restarts the pods of Cilium, so a new setting
    # takes effect without manual restarts.
    rollOutCiliumPods = true
    operator          = { replicas = min(2, local.node_count), rollOutPods = true }
    envoy             = { rollOutPods = true }
    # The certificates of Hubble come from a job, not from Helm. Helm would
    # create new certificates at every plan.
    hubble = {
      enabled = var.cilium.hubble
      relay   = { enabled = var.cilium.hubble }
      ui      = { enabled = false }
      tls     = { auto = { enabled = true, method = "cronJob" } }
    }
  }
}

data "helm_template" "cilium" {
  name         = "cilium"
  namespace    = "kube-system"
  repository   = "https://helm.cilium.io"
  chart        = "cilium"
  version      = var.cilium.chart_version
  kube_version = var.kubernetes_version

  values = [
    yamlencode(local.cilium_values),
    local.cilium_gateway_values,
    yamlencode(var.cilium.helm_values),
  ]
}

data "helm_template" "talos_ccm" {
  name         = "talos-cloud-controller-manager"
  namespace    = "kube-system"
  repository   = "oci://ghcr.io/siderolabs/charts"
  chart        = "talos-cloud-controller-manager"
  version      = var.talos_ccm.chart_version
  kube_version = var.kubernetes_version

  values = [
    yamlencode({
      # cloud-node sets the node addresses. node-csr-approval approves the
      # serving certificates of kubelet.
      enabledControllers = ["cloud-node", "node-csr-approval"]
    }),
    yamlencode(var.talos_ccm.helm_values),
  ]
}

data "helm_template" "metrics_server" {
  count = var.metrics_server.enabled ? 1 : 0

  name         = "metrics-server"
  namespace    = "kube-system"
  repository   = "https://kubernetes-sigs.github.io/metrics-server"
  chart        = "metrics-server"
  version      = var.metrics_server.chart_version
  kube_version = var.kubernetes_version

  values = [
    yamlencode({ replicas = local.node_count > 1 ? 2 : 1 }),
    yamlencode(var.metrics_server.helm_values),
  ]
}

locals {
  inline_manifests = concat(
    # The Gateway API CRDs come first, because the Cilium operator only
    # enables the Gateway API when the CRDs exist at its start.
    [for manifest in local.ingress_manifests : manifest if manifest.name == "gateway-api-crds"],
    [
      { name = "cilium", contents = data.helm_template.cilium.manifest },
      { name = "talos-cloud-controller-manager", contents = data.helm_template.talos_ccm.manifest },
    ],
    var.metrics_server.enabled ? [{ name = "metrics-server", contents = data.helm_template.metrics_server[0].manifest }] : [],
    var.longhorn.enabled ? [{ name = "longhorn", contents = local.longhorn_manifest }] : [],
    [for manifest in local.ingress_manifests : manifest if manifest.name != "gateway-api-crds"],
    local.tailscale_manifests,
    local.backup_manifests,
    [for name in sort(keys(var.extra_manifests)) : { name = "extra-${name}", contents = var.extra_manifests[name] }],
  )

  # Talos only applies changed inline manifests through "talosctl upgrade-k8s".
  # A new checksum runs that step.
  inline_manifests_sha256 = sha256(join("\n", concat(
    [for manifest in local.inline_manifests : "${manifest.name}=${sha256(manifest.contents)}"],
    var.workload_identity.enabled ? [coalesce(module.workload_identity[0].inline_manifests_sha256, "-")] : [],
  )))
}
