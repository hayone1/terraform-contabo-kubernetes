# Live test of a cluster with several nodes.
#
# The test orders new Contabo instances (they cost money for the whole
# contract period), lets the module create the private network and builds a
# cluster with three control plane nodes and Longhorn.
#
# worker_instances adopts instances into a worker pool. The test uses it to
# move control plane nodes into the worker pool (see README.md).

terraform {
  required_version = ">= 1.9.0"

  # run.sh keeps the state outside the repository, because the state holds the
  # Talos machine secrets.
  backend "local" {}

  required_providers {
    contabo = {
      source  = "hayone1/contabo"
      version = ">= 0.3.4, < 0.4.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.12.0, < 0.13.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.1.1, < 4.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = ">= 0.29.3, < 0.30.0"
    }
    headscale = {
      source  = "awlsring/headscale"
      version = ">= 0.5.1, < 0.6.0"
    }
  }
}

provider "contabo" {}

# run.sh sets TAILSCALE_API_KEY with HA_TAILSCALE=1. Without Tailscale
# resources, Terraform never configures the provider.
provider "tailscale" {}

# run.sh sets HEADSCALE_ENDPOINT and HEADSCALE_API_KEY with HA_HEADSCALE=1.
provider "headscale" {}

variable "product_id" {
  description = "The Contabo product of the new instances. V154 is Cloud VPS 6."
  type        = string
  default     = "V154"
}

variable "control_plane_count" {
  type    = number
  default = 3
}

variable "cp_reinstall_generations" {
  description = "Reinstall generations of the control plane nodes, for example { \"2\" = 2 }."
  type        = map(number)
  default     = {}
}

variable "worker_reinstall_generations" {
  description = "Reinstall generations of the workers, for example { b = 2 }."
  type        = map(number)
  default     = {}
}

variable "worker_instances" {
  description = "Instances for the worker pool, as a map from a key to an instance id."
  type        = map(string)
  default     = {}
}

variable "talos_version" {
  type    = string
  default = "v1.14.5"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36.6"
}

variable "work_dir" {
  description = "A folder outside the repository for files with secrets. run.sh sets it."
  type        = string
}

variable "ingress_domain" {
  description = "A domain for the ingress test, for example ha-live.example.com. Empty turns the Gateway, cert-manager and external-dns off."
  type        = string
  default     = ""
}

variable "acme_email" {
  type    = string
  default = ""
}

variable "dns_credentials" {
  description = "Contabo API credentials for cert-manager and external-dns. run.sh sets them from tests/live/.env."
  type = object({
    client_id     = string
    client_secret = string
    api_user      = string
    api_password  = string
  })
  default   = null
  sensitive = true
}

variable "extra_manifests" {
  type    = map(string)
  default = {}
}

variable "tailscale" {
  description = "Turns on the Tailscale node agent and the operator (HA_TAILSCALE=1)."
  type        = bool
  default     = false
}

variable "tailnet_domain" {
  type    = string
  default = null
}

variable "tailscale_workers" {
  description = "Also runs the Tailscale node agent on the workers (HA_TAILSCALE_WORKERS=1)."
  type        = bool
  default     = false
}

variable "admin_mode" {
  description = "admin_access.mode of the module: \"public\" or \"tailscale\"."
  type        = string
  default     = "public"
}

variable "backup_object_storage_id" {
  description = "An object storage for the backup test (HA_BACKUPS=1). The test creates its own bucket."
  type        = string
  default     = null
}

variable "backup_age_public_key" {
  type    = string
  default = null
}

variable "headscale_server" {
  description = "Runs a Headscale server in the cluster at headscale.<ingress_domain>:8443 (HA_HEADSCALE_SERVER=1)."
  type        = bool
  default     = false
}

variable "headscale" {
  description = "The node agents log in to the Headscale server of the cluster instead of the Tailscale service (HA_HEADSCALE=1)."
  type        = bool
  default     = false
}

variable "longhorn_v2" {
  description = "Turns on the V2 Data Engine of Longhorn (HA_LONGHORN_V2=1)."
  type        = bool
  default     = false
}

variable "longhorn_v2_interrupt" {
  description = "Runs the V2 Data Engine in interrupt mode (HA_LONGHORN_V2_INTERRUPT=1)."
  type        = bool
  default     = false
}

# Headscale runs in the cluster that uses it. A real cluster should use a
# Headscale server outside the cluster, but the test has no other server. The
# node agents reach Headscale through the public address, so the cluster
# starts without Headscale.
locals {
  headscale_server = var.headscale_server || var.headscale
  headscale_host   = "headscale.${var.ingress_domain}"
  headscale_url    = "https://${local.headscale_host}:8443"
  # The MagicDNS domain of the Headscale tailnet.
  headscale_domain = "hs.internal"
  headscale_manifest = templatefile("${path.module}/headscale.yaml.tftpl", {
    host        = local.headscale_host
    url         = local.headscale_url
    base_domain = local.headscale_domain
    version     = "0.29.7"
  })
}

module "cluster" {
  source = "../../.."

  cluster_name       = "ha-live"
  region             = "EU"
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  control_plane_pools = [{
    name       = "cp"
    product_id = var.product_id
    count      = var.control_plane_count

    reinstall_generations = var.cp_reinstall_generations
  }]

  worker_pools = length(var.worker_instances) == 0 ? [] : [{
    name               = "w"
    existing_instances = var.worker_instances

    reinstall_generations = var.worker_reinstall_generations
    labels                = { "example.com/tier" = "general" }
    taints                = { "example.com/dedicated" = "general:PreferNoSchedule" }
  }]

  adoption = {
    allow_reinstall   = true
    cancel_on_destroy = true
  }

  public_ports = concat([80, 443], local.headscale_server ? [8443] : [])

  longhorn = { enabled = true, v2 = { enabled = var.longhorn_v2, interrupt_mode = var.longhorn_v2_interrupt } }

  gateway_api  = { enabled = var.ingress_domain != "", domain = var.ingress_domain == "" ? null : var.ingress_domain }
  cert_manager = { enabled = var.ingress_domain != "", acme_email = var.acme_email }
  external_dns = { enabled = var.ingress_domain != "" }

  contabo_dns_credentials = var.dns_credentials

  extra_manifests = merge(var.extra_manifests, local.headscale_server ? { headscale = local.headscale_manifest } : {})

  admin_access = { mode = var.admin_mode }

  # The computer that runs the test joins the tailnet with tag:k8s-admin.
  # Headscale has no autogroup:admin and no operator.
  tailscale = {
    tailnet_domain = var.headscale ? local.headscale_domain : var.tailnet_domain
    login_server   = var.headscale ? local.headscale_url : null
    admin_sources  = var.headscale ? ["tag:k8s-admin"] : ["autogroup:admin", "tag:k8s-admin"]
    tag_owners     = var.headscale ? ["admin@"] : ["autogroup:admin"]
    node_agent     = { enabled = var.tailscale || var.headscale, workers = var.tailscale_workers }
    operator       = { enabled = var.tailscale && !var.headscale }
  }
  tailscale_auth_key     = var.headscale ? headscale_pre_auth_key.nodes[0].key : var.tailscale ? "${tailscale_oauth_client.nodes[0].key}?ephemeral=false&preauthorized=true" : null
  tailscale_oauth_client = var.tailscale && !var.headscale ? { client_id = tailscale_oauth_client.operator[0].id, client_secret = tailscale_oauth_client.operator[0].key } : null

  backups = var.backup_object_storage_id == null ? null : {
    object_storage_id = var.backup_object_storage_id
    bucket            = contabo_object_storage_bucket.backups[0].name
    etcd              = { enabled = true, schedule = "0 */6 * * *", age_public_keys = [var.backup_age_public_key] }
    longhorn          = { enabled = true, schedule = "30 3 * * *", retain = 2 }
  }
}

# Tailscale: the same resources as examples/tailscale-admin, plus an auth key
# for the computer that runs the test. The policy keeps the rules of the
# default policy of a new tailnet (everybody may connect, and the SSH rule).
locals {
  tailscale_policy = var.tailscale ? merge(
    {
      grants = concat(
        [{ src = ["*"], dst = ["*"], ip = ["*"] }],
        jsondecode(module.cluster.tailscale_policy).grants,
      )
      ssh = [{
        action = "check"
        src    = ["autogroup:member"]
        dst    = ["autogroup:self"]
        users  = ["autogroup:nonroot", "root"]
      }]
    },
    { tagOwners = merge(jsondecode(module.cluster.tailscale_policy).tagOwners, { "tag:k8s-admin" = ["autogroup:admin"] }) },
  ) : null
}

resource "tailscale_acl" "this" {
  count                      = var.tailscale ? 1 : 0
  acl                        = jsonencode(local.tailscale_policy)
  overwrite_existing_content = true
}

resource "tailscale_tailnet_settings" "this" {
  count         = var.tailscale ? 1 : 0
  https_enabled = true
}

resource "tailscale_oauth_client" "nodes" {
  count       = var.tailscale ? 1 : 0
  description = "ha-live nodes"
  scopes      = ["auth_keys"]
  tags        = ["tag:k8s-node"]
  depends_on  = [tailscale_acl.this]
}

resource "tailscale_oauth_client" "operator" {
  count       = var.tailscale ? 1 : 0
  description = "ha-live operator"
  scopes      = ["devices:core", "auth_keys", "services"]
  tags        = ["tag:k8s-operator"]
  depends_on  = [tailscale_acl.this]
}

resource "tailscale_tailnet_key" "runner" {
  count         = var.tailscale ? 1 : 0
  description   = "ha-live test runner"
  reusable      = true
  preauthorized = true
  tags          = ["tag:k8s-admin"]
  expiry        = 7 * 24 * 3600
  depends_on    = [tailscale_acl.this]
}

resource "local_sensitive_file" "runner_key" {
  count    = var.tailscale ? 1 : 0
  content  = tailscale_tailnet_key.runner[0].key
  filename = "${var.work_dir}/tailscale-runner-key"
}

# Headscale: the same resources as examples/headscale-admin, plus a key for
# the computer that runs the test. headscale_policy needs the policy mode
# "database" of Headscale.
resource "headscale_user" "admin" {
  count = var.headscale ? 1 : 0
  name  = "admin"
}

resource "headscale_policy" "this" {
  count = var.headscale ? 1 : 0
  policy = jsonencode(merge(
    jsondecode(module.cluster.tailscale_policy),
    { tagOwners = merge(jsondecode(module.cluster.tailscale_policy).tagOwners, { "tag:k8s-admin" = ["admin@"] }) },
  ))
  depends_on = [headscale_user.admin]
}

resource "headscale_pre_auth_key" "nodes" {
  count          = var.headscale ? 1 : 0
  reusable       = true
  acl_tags       = ["tag:k8s-node"]
  time_to_expire = "90d"
  depends_on     = [headscale_policy.this]
}

resource "headscale_pre_auth_key" "runner" {
  count          = var.headscale ? 1 : 0
  reusable       = true
  acl_tags       = ["tag:k8s-admin"]
  time_to_expire = "7d"
  depends_on     = [headscale_policy.this]
}

resource "local_sensitive_file" "headscale_runner_key" {
  count    = var.headscale ? 1 : 0
  content  = headscale_pre_auth_key.runner[0].key
  filename = "${var.work_dir}/headscale-runner-key"
}

# The bucket of the backup test.
resource "contabo_object_storage_bucket" "backups" {
  count             = var.backup_object_storage_id == null ? 0 : 1
  name              = "ha-live-backups"
  object_storage_id = var.backup_object_storage_id
}

resource "local_sensitive_file" "kubeconfig" {
  content  = module.cluster.kubeconfig
  filename = "${var.work_dir}/kubeconfig"
}

resource "local_sensitive_file" "talosconfig" {
  content  = module.cluster.talosconfig
  filename = "${var.work_dir}/talosconfig"
}

output "nodes" {
  value = module.cluster.nodes
}

output "kubernetes_api_url" {
  value = module.cluster.kubernetes_api_url
}

output "private_network" {
  value = module.cluster.private_network
}

output "tailscale" {
  value = module.cluster.tailscale
}

output "headscale_url" {
  value = local.headscale_server ? local.headscale_url : null
}
