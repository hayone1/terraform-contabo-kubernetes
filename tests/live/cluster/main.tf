# Live test of the root module.
#
# The test adopts one existing Contabo instance, erases it and builds a
# one-node cluster with workload identity. It also creates an Entra ID
# application that trusts one service account, so run.sh can check the token
# exchange of a pod.
#
# The instance must already be in the private network private_network_id.
# The test never changes that network.

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
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.10"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "contabo" {}
provider "azuread" {}

variable "instance_id" {
  description = "The Contabo instance that the test erases and adopts."
  type        = string
}

variable "private_network_id" {
  description = "An existing private network that already contains the instance."
  type        = string
}

variable "object_storage_id" {
  description = "An existing object storage for the issuer bucket."
  type        = string
}

variable "talos_version" {
  type    = string
  default = "v1.14.5"
}

variable "kubernetes_version" {
  description = "Rancher 2.15 (examples/rancher-entra-login) supports Kubernetes below 1.37."
  type        = string
  default     = "1.36.6"
}

variable "reinstall_generation" {
  description = "Raise the number to erase the node and to install Talos again."
  type        = number
  default     = 1
}

variable "work_dir" {
  description = "A folder outside the repository for files with secrets. run.sh sets it."
  type        = string
}

variable "extra_control_plane_patch_files" {
  description = "Paths of extra Talos patches for the control plane, for example the KubeAuthenticationConfig patch of examples/headlamp-entra-login."
  type        = list(string)
  default     = []
}

data "azuread_client_config" "current" {}

module "cluster" {
  source = "../../.."

  cluster_name       = "wi-live"
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  control_plane_pools = [{
    name                  = "cp"
    existing_instances    = { a = var.instance_id }
    reinstall_generations = { a = var.reinstall_generation }
  }]

  adoption = {
    allow_reinstall   = true
    cancel_on_destroy = false
  }

  private_network = { existing_id = var.private_network_id }

  # The example tests run Traefik with host ports.
  public_ports = [80, 443]

  talos = {
    control_plane_config_patches = [for path in var.extra_control_plane_patch_files : file(path)]
  }

  workload_identity = {
    enabled = true
    issuer = {
      object_storage = { object_storage_id = var.object_storage_id }
    }
    azure = { tenant_id = data.azuread_client_config.current.tenant_id }
  }
}

resource "local_sensitive_file" "kubeconfig" {
  content  = module.cluster.kubeconfig
  filename = "${var.work_dir}/kubeconfig"
}

resource "local_sensitive_file" "talosconfig" {
  content  = module.cluster.talosconfig
  filename = "${var.work_dir}/talosconfig"
}

# Entra ID side of the token exchange test.
resource "azuread_application" "test" {
  display_name     = "wi-live-cluster-test"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "test" {
  client_id = azuread_application.test.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_federated_identity_credential" "test" {
  application_id = azuread_application.test.id
  display_name   = "wi-live-wi-test-wi-test"
  issuer         = module.cluster.workload_identity.issuer_url
  subject        = "system:serviceaccount:wi-test:wi-test"
  audiences      = [module.cluster.workload_identity.azure.audience]
}

output "client_id" {
  value = azuread_application.test.client_id
}

output "tenant_id" {
  value = data.azuread_client_config.current.tenant_id
}

output "issuer_url" {
  value = module.cluster.workload_identity.issuer_url
}

output "nodes" {
  value = module.cluster.nodes
}

output "kubernetes_api_url" {
  value = module.cluster.kubernetes_api_url
}

output "kubeconfig" {
  value     = module.cluster.kubeconfig
  sensitive = true
}

output "talosconfig" {
  value     = module.cluster.talosconfig
  sensitive = true
}
