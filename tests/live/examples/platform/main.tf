# Prerequisites for the live tests of examples/headlamp-entra-login and
# examples/rancher-entra-login on the one-node test cluster:
#
# - Traefik as the ingress controller, on the host ports 80 and 443
# - cert-manager with Let's Encrypt ClusterIssuers (HTTP-01)
# - DNS records for the test host names in a Contabo DNS zone
# - an Entra ID group with the signed-in Azure CLI user as its member
#
# The main module of this repository will provide ingress and certificates
# later (PLAN.md, phase 3). This harness is not an example.

terraform {
  required_version = ">= 1.9.0"

  backend "local" {}

  required_providers {
    contabo = {
      source = "hayone1/contabo"
      # 0.3.1 fixes a bucket update that turned public sharing off.
      version = ">= 0.3.1, < 0.4.0"
    }
    helm = {
      source = "hashicorp/helm"
      # upgrade_install and take_ownership need 3.1.0; 3.1.1 fixes an
      # "inconsistent result after apply" bug of helm_release.
      version = ">= 3.1.1, < 4.0.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.10"
    }
  }
}

variable "kubeconfig_path" {
  type = string
}

variable "node_ip" {
  type = string
}

variable "dns_zone" {
  description = "A DNS zone on the Contabo name servers."
  type        = string
}

variable "host_labels" {
  description = "The host names to create in the zone."
  type        = list(string)
  default     = ["headlamp-wi-live", "rancher-wi-live"]
}

variable "group_name" {
  type    = string
  default = "wi-live-k8s-admins"
}

provider "contabo" {}
provider "azuread" {}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes = {
    config_path = var.kubeconfig_path
  }
}

data "azuread_client_config" "current" {}

resource "azuread_group" "admins" {
  display_name     = var.group_name
  description      = "Live test of terraform-contabo-kubernetes: cluster and Rancher administrators."
  security_enabled = true
  owners           = [data.azuread_client_config.current.object_id]
  members          = [data.azuread_client_config.current.object_id]
}

resource "contabo_dns_record" "hosts" {
  for_each = toset(var.host_labels)

  zone_name = var.dns_zone
  name      = each.value
  type      = "A"
  ttl       = 300
  data      = var.node_ip
}

# Host ports need the privileged Pod Security level.
resource "kubernetes_namespace_v1" "traefik" {
  metadata {
    name = "traefik"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

resource "helm_release" "traefik" {
  name = "traefik"
  # Repairs a release that a failed apply left behind.
  upgrade_install = true
  namespace       = kubernetes_namespace_v1.traefik.metadata[0].name
  repository      = "https://traefik.github.io/charts"
  chart           = "traefik"
  version         = "42.3.1"
  wait            = true

  values = [yamlencode({
    ingressClass = { enabled = true, isDefaultClass = true, name = "traefik" }
    providers = {
      kubernetesIngress = { enabled = true }
      kubernetesCRD     = { enabled = false }
    }
    ports = {
      web       = { hostPort = 80 }
      websecure = { hostPort = 443 }
    }
    service = { enabled = false }
  })]
}

resource "helm_release" "cert_manager" {
  name = "cert-manager"
  # Repairs a release that a failed apply left behind.
  upgrade_install  = true
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.21.3"
  wait             = true

  values = [yamlencode({
    crds = { enabled = true }
  })]
}

resource "helm_release" "cluster_issuers" {
  name = "cluster-issuers"
  # Repairs a release that a failed apply left behind.
  upgrade_install = true
  namespace       = helm_release.cert_manager.namespace
  chart           = "${path.module}/charts/cluster-issuers"

  depends_on = [helm_release.cert_manager, helm_release.traefik]
}

output "admin_group_object_id" {
  value = azuread_group.admins.object_id
}

output "hostnames" {
  value = { for label, record in contabo_dns_record.hosts : label => "${label}.${var.dns_zone}" }
}
