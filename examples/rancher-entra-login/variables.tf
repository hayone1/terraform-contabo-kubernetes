variable "kubeconfig_path" {
  description = "The path of a kubeconfig file with cluster-admin access to the cluster."
  type        = string
}

variable "kubeconfig_context" {
  description = "The kubeconfig context to use. Leave it empty to use the current context of the file."
  type        = string
  default     = null
}

variable "tenant_id" {
  description = "The ID of the Entra ID tenant whose users log in to Rancher."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "The tenant_id value must be a GUID."
  }
}

variable "issuer_url" {
  description = "The service account issuer of the cluster. Use the issuer_url output of the workload identity module."
  type        = string

  validation {
    condition     = can(regex("^https://[^/?#]+(/[^?#]*[^/?#])?$", var.issuer_url))
    error_message = "The issuer_url value must start with https://, and it must not have a slash at the end."
  }
}

variable "hostname" {
  description = "The public host name of Rancher, for example rancher.example.com. A DNS record must point the name to the ingress controller."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.hostname))
    error_message = "The hostname value must be a lowercase DNS name, for example rancher.example.com."
  }
}

variable "ingress" {
  description = <<-EOT
    How users reach Rancher.
    class_name is the ingress class of your ingress controller.
    cluster_issuer is the name of a cert-manager ClusterIssuer that issues a publicly trusted TLS certificate. Set it to null when you create the TLS secret "cattle-system/tls-rancher-ingress" yourself.
    annotations are extra annotations for the Ingress object.
  EOT
  type = object({
    class_name     = string
    cluster_issuer = optional(string)
    annotations    = optional(map(string), {})
  })
}

variable "admin_group_object_ids" {
  description = "Entra ID groups whose members become Rancher administrators."
  type        = list(string)

  validation {
    condition = length(var.admin_group_object_ids) > 0 && alltrue([
      for id in var.admin_group_object_ids : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))
    ])
    error_message = "List at least one admin group. Every group object ID must be a GUID."
  }
}

variable "user_group_object_ids" {
  description = "Entra ID groups whose members become standard Rancher users. Standard users can log in and create their own clusters, but they only see clusters and projects that somebody shares with them."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for id in var.user_group_object_ids : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))])
    error_message = "Every group object ID must be a GUID."
  }
}

variable "rancher" {
  description = <<-EOT
    The Rancher installation.
    replicas is the number of Rancher server pods. Use 3 on a cluster with three or more nodes.
    helm_values are extra values for the Rancher chart. They override the values of the example.
  EOT
  type = object({
    chart_version = optional(string, "2.15.3")
    replicas      = optional(number, 3)
    helm_values   = optional(any, {})
  })
  default  = {}
  nullable = false
}

variable "secret_rotation" {
  description = <<-EOT
    The rotation of the client secret that Rancher uses for Entra ID.
    Rancher cannot log in to Entra ID with a federated credential, so it needs a client secret. A job in the cluster creates short-lived secrets with workload identity and hands them to Rancher. No secret is stored in Terraform.
    lifetime_days is how long one secret is valid. renew_before_days is how many days before the end the job creates the next secret. schedule is when the job runs, in cron format (UTC).
  EOT
  type = object({
    lifetime_days     = optional(number, 30)
    renew_before_days = optional(number, 10)
    schedule          = optional(string, "17 3 * * *")
    namespace         = optional(string, "rancher-entra-auth")
    # Pinned by digest, because the job handles a client secret.
    image = optional(string, "docker.io/alpine/k8s:1.36.6@sha256:182daef60c9413848a914435a2c37ccd3088870e2ea989e7667687a109945c28")
  })
  default  = {}
  nullable = false

  validation {
    condition = (
      var.secret_rotation.lifetime_days >= 2 && var.secret_rotation.lifetime_days <= 730 &&
      floor(var.secret_rotation.lifetime_days) == var.secret_rotation.lifetime_days &&
      var.secret_rotation.renew_before_days >= 1 &&
      floor(var.secret_rotation.renew_before_days) == var.secret_rotation.renew_before_days &&
      var.secret_rotation.renew_before_days < var.secret_rotation.lifetime_days
    )
    error_message = "The lifetime_days value must be a whole number between 2 and 730. The renew_before_days value must be a whole number of at least 1 and smaller than lifetime_days."
  }
}
