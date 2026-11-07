# Live test for modules/workload-identity.
#
# It builds a one-node Talos cluster on an existing Contabo instance that
# already runs Talos in maintenance mode, publishes the issuer documents in a
# Contabo bucket, and creates an Entra ID application that trusts the cluster.
# run.sh then starts a pod and exchanges its token at Entra ID.
#
# This is a test harness, not an example of the final module layout.

terraform {
  required_version = ">= 1.9.0"

  # run.sh keeps the state outside the repository, because the state holds the
  # Talos machine secrets.
  backend "local" {}

  required_providers {
    contabo = {
      source = "hayone1/contabo"
      # 0.3.1 fixes a bucket update that turned public sharing off.
      version = ">= 0.3.1, < 0.4.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
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
provider "helm" {}
provider "azuread" {}

variable "cluster_name" {
  type    = string
  default = "wi-live"
}

variable "node_ip" {
  description = "Public IPv4 address of the test instance (Talos in maintenance mode)."
  type        = string
}

variable "object_storage_id" {
  type = string
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

variable "work_dir" {
  description = "A folder outside the repository for files with secrets. run.sh sets it."
  type        = string
}

variable "extra_control_plane_patch_files" {
  description = "Paths of extra Talos patches for the control plane, for example the KubeAuthenticationConfig patch of examples/headlamp-entra-login."
  type        = list(string)
  default     = []
}

variable "talos_schematic_id" {
  description = "Image Factory schematic of the image on the instance. Talos upgrades keep its kernel arguments."
  type        = string
}

variable "oidc_bucket_name" {
  description = "Used by the edge-case tests to try a different issuer."
  type        = string
  default     = null
}

variable "webhook_helm_values" {
  description = "Used by the edge-case tests to change the webhook manifests."
  type        = any
  default     = {}
}

variable "issuer_generation" {
  type    = number
  default = 1
}

variable "additional_accepted_issuers" {
  type    = list(string)
  default = []
}

variable "service_account_name" {
  type    = string
  default = "wi-test"
}

variable "service_account_namespace" {
  type    = string
  default = "wi-test"
}

locals {
  endpoint = "https://${var.node_ip}:6443"
}

data "azuread_client_config" "current" {}

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

module "workload_identity" {
  source = "../../../modules/workload-identity"

  cluster_name = var.cluster_name

  issuer = {
    object_storage = {
      object_storage_id = var.object_storage_id
      bucket_name       = var.oidc_bucket_name
    }
  }

  # Talos stores the service account key base64-encoded.
  service_account_public_keys_pem = [base64decode(talos_machine_secrets.this.machine_secrets.certs.k8s_serviceaccount.key)]
  issuer_generation               = var.issuer_generation
  additional_accepted_issuers     = var.additional_accepted_issuers

  kubernetes_api = {
    url                    = local.endpoint
    ca_certificate_pem     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
    client_certificate_pem = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
    client_key_pem         = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  }

  azure = {
    enabled             = true
    tenant_id           = data.azuread_client_config.current.tenant_id
    kubernetes_version  = var.kubernetes_version
    webhook_helm_values = var.webhook_helm_values
  }
}

data "talos_machine_configuration" "control_plane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = concat([
    yamlencode({
      machine = {
        certSANs = [var.node_ip]
      }
    }),
    # Talos 1.14 keeps these settings in their own documents.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UnattendedInstallConfig"
      installer  = { image = "factory.talos.dev/installer/${var.talos_schematic_id}:${var.talos_version}" }
      provisioning = {
        diskSelector = { match = "disk.dev_path == \"/dev/sda\"" }
      }
    }),
    # One node runs the workloads too, so remove the control plane taint.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeNodeConfig"
      taints = {
        "node-role.kubernetes.io/control-plane" = { "$patch" = "delete" }
      }
    }),
    module.workload_identity.talos_config_patch,
  ], [for path in var.extra_control_plane_patch_files : file(path)])
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [var.node_ip]
  nodes                = [var.node_ip]
}

resource "talos_machine_configuration_apply" "control_plane" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_plane.machine_configuration
  node                        = var.node_ip
  endpoint                    = var.node_ip
}

resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.node_ip
  endpoint             = var.node_ip

  depends_on = [talos_machine_configuration_apply.control_plane]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.node_ip
  endpoint             = var.node_ip

  depends_on = [talos_machine_bootstrap.this]
}

# Talos stores changed inline manifests but does not apply them. This step
# applies them when the checksum changes, as the module README describes.
resource "local_sensitive_file" "talosconfig" {
  content  = data.talos_client_configuration.this.talos_config
  filename = "${var.work_dir}/talosconfig"
}

resource "terraform_data" "sync_manifests" {
  triggers_replace = module.workload_identity.inline_manifests_sha256

  provisioner "local-exec" {
    command = "talosctl --talosconfig '${local_sensitive_file.talosconfig.filename}' -n ${var.node_ip} -e ${var.node_ip} health --wait-timeout 15m && talosctl --talosconfig '${local_sensitive_file.talosconfig.filename}' -n ${var.node_ip} -e ${var.node_ip} upgrade-k8s --to ${var.kubernetes_version}"
  }

  depends_on = [talos_cluster_kubeconfig.this]
}

# Entra ID side. The module does not manage Entra ID objects; this test does.
resource "azuread_application" "test" {
  display_name     = "wi-live-${var.cluster_name}"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "test" {
  client_id = azuread_application.test.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_federated_identity_credential" "test" {
  application_id = azuread_application.test.id
  display_name   = "${var.cluster_name}-${var.service_account_namespace}-${var.service_account_name}"
  issuer         = module.workload_identity.issuer_url
  subject        = "system:serviceaccount:${var.service_account_namespace}:${var.service_account_name}"
  audiences      = [module.workload_identity.azure.audience]
}

output "issuer_url" {
  value = module.workload_identity.issuer_url
}

output "key_ids" {
  value = module.workload_identity.key_ids
}

output "client_id" {
  value = azuread_application.test.client_id
}

output "tenant_id" {
  value = data.azuread_client_config.current.tenant_id
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}
