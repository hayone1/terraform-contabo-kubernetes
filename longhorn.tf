# Longhorn stores persistent volumes on the disks of the nodes, because
# Contabo has no cloud volumes. Talos limits its EPHEMERAL volume and gives the
# rest of the disk to the user volume "longhorn" (/var/mnt/longhorn).

locals {
  # Longhorn runs where pods run: on the worker nodes, or on the control plane
  # nodes when the cluster has no worker nodes.
  longhorn_keys = var.longhorn.enabled ? [
    for key, node in local.nodes : key if node.role == "worker" || local.control_plane_schedulable
  ] : []

  # Talos sets this label on the Longhorn nodes. The pods of Longhorn only run
  # on nodes with the label, so a node that stops being a Longhorn node (for
  # example a control plane node after the first worker pool) loses them.
  longhorn_label = "node.kubernetes.io/longhorn"

  longhorn_extensions = var.longhorn.enabled ? ["siderolabs/iscsi-tools", "siderolabs/util-linux-tools"] : []

  longhorn_replica_count = coalesce(var.longhorn.replica_count, min(3, max(1, length(local.longhorn_keys))))

  # The V2 Data Engine keeps its volumes on a raw partition (a block disk for
  # Longhorn) instead of a file system.
  longhorn_v2      = var.longhorn.enabled && var.longhorn.v2.enabled
  longhorn_v2_disk = "/dev/disk/by-partlabel/r-longhorn-v2"

  # SPDK, the storage engine of v2, needs 1024 hugepages of 2 MiB. kubelet
  # counts hugepages only when it starts, and Longhorn refuses v2 while a
  # Longhorn node offers no hugepages. Kernel arguments reserve the hugepages
  # at boot, and a changed schematic makes the module upgrade (and restart)
  # the running nodes.
  longhorn_v2_kernel_args = local.longhorn_v2 ? ["hugepagesz=2M", "hugepages=1024"] : []

  # The disk layout of a storage node. Talos reads the layout from the first
  # configuration of the node and does not shrink an existing volume. Talos
  # creates partitions with a fixed size before partitions that grow, so the
  # raw partition of v2 gets its size, and the user volume gets the rest.
  longhorn_volume_patches = concat(
    [
      yamlencode({
        apiVersion   = "v1alpha1"
        kind         = "VolumeConfig"
        name         = "EPHEMERAL"
        provisioning = { maxSize = var.longhorn.ephemeral_max_size }
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "UserVolumeConfig"
        name       = "longhorn"
        provisioning = {
          diskSelector = { match = "system_disk" }
          minSize      = var.longhorn.min_size
          grow         = true
        }
        filesystem = { type = "xfs" }
      }),
    ],
    local.longhorn_v2 ? [
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "RawVolumeConfig"
        name       = "longhorn-v2"
        provisioning = {
          diskSelector = { match = "system_disk" }
          minSize      = var.longhorn.v2.size
          maxSize      = var.longhorn.v2.size
        }
      }),
    ] : [],
    [for module in(local.longhorn_v2 ? ["nvme_tcp", "vfio_pci", "uio_pci_generic", "ublk_drv"] : []) : yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KernelModuleConfig"
      name       = module
    })],
  )

  # Longhorn creates the disks of a new Longhorn node from this annotation
  # (with createDefaultDiskLabeledNodes). A node that already has disks keeps
  # them.
  longhorn_v2_node_labels = local.longhorn_v2 ? { "node.longhorn.io/create-default-disk" = "config" } : {}
  longhorn_v2_node_annotations = local.longhorn_v2 ? {
    "node.longhorn.io/default-disks-config" = jsonencode([
      { name = "longhorn", path = "/var/mnt/longhorn", allowScheduling = true },
      { name = "longhorn-v2", path = local.longhorn_v2_disk, diskType = "block", allowScheduling = true },
    ])
  } : {}

  longhorn_v2_storage_class = yamlencode({
    apiVersion           = "storage.k8s.io/v1"
    kind                 = "StorageClass"
    metadata             = { name = "longhorn-v2" }
    provisioner          = "driver.longhorn.io"
    allowVolumeExpansion = true
    reclaimPolicy        = "Delete"
    volumeBindingMode    = "Immediate"
    parameters = {
      numberOfReplicas    = tostring(local.longhorn_replica_count)
      staleReplicaTimeout = "30"
      fsType              = "ext4"
      dataEngine          = "v2"
    }
  })

  longhorn_namespace = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "longhorn-system"
      # Longhorn needs privileged pods. Talos enforces the "baseline" pod
      # security level by default.
      labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
        "pod-security.kubernetes.io/audit"   = "privileged"
        "pod-security.kubernetes.io/warn"    = "privileged"
      }
    }
  })
}

data "helm_template" "longhorn" {
  count = var.longhorn.enabled ? 1 : 0

  name         = "longhorn"
  namespace    = "longhorn-system"
  repository   = "https://charts.longhorn.io"
  chart        = "longhorn"
  version      = var.longhorn.chart_version
  kube_version = var.kubernetes_version
  include_crds = true

  values = [
    yamlencode({
      defaultSettings = merge(
        {
          defaultDataPath                     = "/var/mnt/longhorn"
          defaultReplicaCount                 = local.longhorn_replica_count
          systemManagedComponentsNodeSelector = "${local.longhorn_label}:true"
        },
        # Longhorn keeps the last value of a setting that leaves the
        # ConfigMap, so the module always sends these settings.
        {
          v2DataEngine                  = local.longhorn_v2
          createDefaultDiskLabeledNodes = local.longhorn_v2
        },
        local.longhorn_v2 ? { dataEngineInterruptModeEnabled = jsonencode({ v2 = tostring(var.longhorn.v2.interrupt_mode) }) } : {},
      )
      longhornManager = { nodeSelector = { (local.longhorn_label) = "true" } }
      longhornDriver  = { nodeSelector = { (local.longhorn_label) = "true" } }
      persistence = {
        defaultClass             = var.longhorn.default_storage_class
        defaultClassReplicaCount = local.longhorn_replica_count
      }
      # Helm hooks never run in inline manifests.
      preUpgradeChecker = { jobEnabled = false, upgradeVersionCheck = false }
      longhornUI        = { replicas = min(2, max(1, length(local.longhorn_keys))) }
    }),
    local.longhorn_backup_values,
    yamlencode(var.longhorn.helm_values),
  ]
}

locals {
  # Talos applies every document of an inline manifest, also Helm hooks. The
  # uninstall hook of Longhorn would delete Longhorn, so the module drops all
  # hook documents.
  longhorn_manifest = var.longhorn.enabled ? join("\n---\n", concat(
    [local.longhorn_namespace],
    [for document in split("\n---\n", data.helm_template.longhorn[0].manifest) : document if !strcontains(document, "helm.sh/hook")],
    local.longhorn_v2 ? [local.longhorn_v2_storage_class] : [],
    local.longhorn_backup_documents,
  )) : ""

  # Dedicated servers (VDS) have their own CPU cores. On a VPS, the busy cores
  # of v2 take CPU time from the other customers of the host, and the host
  # takes it back.
  vds_products = ["V8", "V9", "V10", "V11", "V16"]
}

check "longhorn_v2_on_vds" {
  assert {
    condition     = !local.longhorn_v2 || var.longhorn.v2.interrupt_mode || alltrue([for key in local.longhorn_keys : contains(local.vds_products, coalesce(contabo_instance.node[key].product_id, "-"))])
    error_message = "The V2 Data Engine of Longhorn keeps 2 CPU cores of every Longhorn node busy. Some Longhorn nodes are no dedicated server (VDS), where the cores are shared with other customers. Use VDS products, or set longhorn.v2.interrupt_mode = true."
  }
}
