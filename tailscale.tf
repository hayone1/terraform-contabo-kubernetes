# Tailscale gives admins a private path to the cluster. The node agent (the
# Talos extension siderolabs/tailscale) puts the Talos API and the Kubernetes
# API of a node on the tailnet. The operator adds the API server proxy, where
# admins log in to Kubernetes with their Tailscale identity. Tailscale never
# carries traffic between the nodes or the pods.

locals {
  tailscale_agent    = var.tailscale.node_agent.enabled
  tailscale_operator = var.tailscale.operator.enabled
  tailscale_mode     = var.admin_access.mode == "tailscale"

  # The agent runs on the control plane nodes, and on the workers when the
  # user asks for it.
  tailscale_keys = local.tailscale_agent ? [
    for key, node in local.nodes : key if node.role == "controlplane" || var.tailscale.node_agent.workers
  ] : []

  # The MagicDNS name of every node with the agent. Tailscale adds a number to
  # the name when another device already has the name, for example the old
  # device of a reinstalled node. The README explains the cleanup.
  tailnet_names = {
    for key in local.tailscale_keys : key => "${local.nodes[key].name}.${coalesce(var.tailscale.tailnet_domain, "-")}"
  }

  tailscale_extensions = ["siderolabs/tailscale"]

  # Userspace mode creates no network interface and changes no route or
  # firewall rule, so Tailscale cannot disturb Cilium. Tailscale hands the
  # connections to the local ports of the node. The node agent ignores the
  # DNS settings of the tailnet, and it logs in only once: later restarts keep
  # the device, even after the auth key expires.
  # Headscale takes the tags from the pre-auth key, and it refuses tags that
  # a device with a key without a user asks for ("requested tags ... are
  # invalid or not permitted").
  tailscale_extra_args = join(" ", concat(
    var.tailscale.login_server == null ? ["--advertise-tags=${join(",", var.tailscale.node_agent.tags)}"] : ["--login-server=${var.tailscale.login_server}"],
    var.tailscale.node_agent.extra_args,
  ))

  # TS_AUTH_ONCE keeps the login of a node, also when the login server
  # changes. So every Headscale server gets its own state directory, and a
  # node that moves to another login server logs in again with the new auth
  # key. The Tailscale service keeps the default directory of the extension.
  tailscale_state_dir = var.tailscale.login_server == null ? null : "/var/lib/tailscale/${try(join("-", compact(regex("^https?://([a-z0-9.-]+)(?::([0-9]+))?", var.tailscale.login_server))), "headscale")}"

  tailscale_patches = {
    for key in local.tailscale_keys : key => yamlencode({
      apiVersion = "v1alpha1"
      kind       = "ExtensionServiceConfig"
      name       = "tailscale"
      environment = concat(
        [
          "TS_AUTHKEY=${coalesce(var.tailscale_auth_key, "-")}",
          "TS_HOSTNAME=${local.nodes[key].name}",
          "TS_USERSPACE=true",
          "TS_ACCEPT_DNS=false",
          "TS_AUTH_ONCE=true",
          "TS_EXTRA_ARGS=${local.tailscale_extra_args}",
        ],
        local.tailscale_state_dir == null ? [] : ["TS_STATE_DIR=${local.tailscale_state_dir}"],
      )
    })
  }

  # The address of the Kubernetes API of every control plane node for the
  # computer that runs Terraform.
  kubernetes_api_host_of = {
    for key in local.control_plane_keys : key => local.tailscale_mode ? local.tailnet_names[key] : local.public_ipv4[key]
  }

  tailscale_operator_hostname = coalesce(var.tailscale.operator.hostname, "${var.cluster_name}-k8s")
}

data "helm_template" "tailscale_operator" {
  count = local.tailscale_operator ? 1 : 0

  name         = "tailscale-operator"
  namespace    = "tailscale"
  repository   = "https://pkgs.tailscale.com/helmcharts"
  chart        = "tailscale-operator"
  version      = var.tailscale.operator.chart_version
  kube_version = var.kubernetes_version

  values = [
    yamlencode({
      # The module writes the Secret "operator-oauth" itself, so the OAuth
      # secret never goes through Helm.
      oauth = {}
      operatorConfig = {
        hostname    = local.tailscale_operator_hostname
        defaultTags = var.tailscale.operator.tags
      }
      proxyConfig = { defaultTags = join(",", var.tailscale.operator.proxy_tags) }
      # "true" is the auth mode: the proxy passes the Tailscale identity of the
      # caller to Kubernetes, and Kubernetes RBAC decides.
      apiServerProxyConfig = { mode = "true" }
    }),
    yamlencode(var.tailscale.operator.helm_values),
  ]
}

locals {
  tailscale_operator_manifest = local.tailscale_operator ? join("\n---\n", concat(
    [
      yamlencode({
        apiVersion = "v1"
        kind       = "Namespace"
        metadata = {
          name = "tailscale"
          # The proxies of the operator need privileged init containers.
          labels = {
            "pod-security.kubernetes.io/enforce" = "privileged"
            "pod-security.kubernetes.io/audit"   = "privileged"
            "pod-security.kubernetes.io/warn"    = "privileged"
          }
        }
      }),
      yamlencode({
        apiVersion = "v1"
        kind       = "Secret"
        metadata   = { name = "operator-oauth", namespace = "tailscale" }
        type       = "Opaque"
        stringData = var.tailscale_oauth_client == null ? {} : {
          client_id     = var.tailscale_oauth_client.client_id
          client_secret = var.tailscale_oauth_client.client_secret
        }
      }),
    ],
    [for document in split("\n---\n", data.helm_template.tailscale_operator[0].manifest) : document if !strcontains(document, "helm.sh/hook") && !strcontains(document, "name: operator-oauth\n")],
    [for group in sort(keys(var.tailscale.operator.cluster_role_bindings)) : yamlencode({
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "ClusterRoleBinding"
      metadata   = { name = "tailscale:${replace(lower(group), "/[^a-z0-9.-]/", "-")}" }
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io"
        kind     = "ClusterRole"
        name     = var.tailscale.operator.cluster_role_bindings[group]
      }
      subjects = [{ apiGroup = "rbac.authorization.k8s.io", kind = "Group", name = group }]
    })],
  )) : ""

  tailscale_manifests = local.tailscale_operator ? [{ name = "tailscale-operator", contents = local.tailscale_operator_manifest }] : []

  # Tags and grants that the tailnet policy needs. The module does not change
  # the policy itself. The example tailscale-admin shows how the Tailscale
  # Terraform provider can apply the policy.
  tailscale_admin_sources = var.tailscale.admin_sources
  # The grants have different attributes, so a filter ("if") selects them
  # instead of a conditional, which needs equal types.
  tailscale_policy = {
    tagOwners = merge(
      { for tag in var.tailscale.node_agent.tags : tag => var.tailscale.tag_owners if local.tailscale_agent },
      { for tag in var.tailscale.operator.tags : tag => var.tailscale.tag_owners if local.tailscale_operator },
      { for tag in var.tailscale.operator.proxy_tags : tag => var.tailscale.operator.tags if local.tailscale_operator },
    )
    grants = [for grant in [
      {
        enabled = local.tailscale_agent
        grant = jsonencode({
          src = local.tailscale_admin_sources
          dst = var.tailscale.node_agent.tags
          ip  = ["tcp:6443", "tcp:50000"]
        })
      },
      {
        enabled = local.tailscale_operator
        grant = jsonencode({
          src = local.tailscale_admin_sources
          dst = var.tailscale.operator.tags
          ip  = ["tcp:443"]
        })
      },
      {
        enabled = local.tailscale_operator
        grant = jsonencode({
          src = local.tailscale_admin_sources
          dst = var.tailscale.operator.tags
          app = {
            "tailscale.com/cap/kubernetes" = [{ impersonate = { groups = sort(keys(var.tailscale.operator.cluster_role_bindings)) } }]
          }
        })
      },
    ] : jsondecode(grant.grant) if grant.enabled]
  }
}

# Headscale has no autogroup:admin, and it refuses a policy with unknown
# names. The warning keeps the plan going, because the module never applies
# the policy itself.
check "headscale_policy_names" {
  assert {
    condition     = var.tailscale.login_server == null || !contains(concat(var.tailscale.admin_sources, var.tailscale.tag_owners), "autogroup:admin")
    error_message = "Headscale has no \"autogroup:admin\", so Headscale refuses the output tailscale_policy. Set tailscale.admin_sources and tailscale.tag_owners to Headscale users, groups or tags, for example [\"admin@\"]."
  }
}
