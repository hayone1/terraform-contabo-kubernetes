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
  description = "The ID of the Entra ID tenant whose users log in to Headlamp."
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
  description = "The public host name of Headlamp, for example headlamp.example.com. A DNS record must point the name to the ingress controller."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.hostname))
    error_message = "The hostname value must be a lowercase DNS name, for example headlamp.example.com."
  }
}

variable "ingress" {
  description = <<-EOT
    How users reach Headlamp.
    class_name is the ingress class of your ingress controller.
    cluster_issuer is the name of a cert-manager ClusterIssuer that issues the TLS certificate. Set it to null when you manage the certificate yourself, and create the TLS secret "<namespace>/headlamp-tls".
    annotations are extra annotations for the Ingress object.
    trusted_proxy_cidrs are the addresses from which oauth2-proxy accepts X-Forwarded-* headers. Use the pod network of your cluster when the ingress controller runs in pods (the Talos default is 10.244.0.0/16), or the node addresses when the ingress controller uses the host network.
  EOT
  type = object({
    class_name          = string
    cluster_issuer      = optional(string)
    annotations         = optional(map(string), {})
    trusted_proxy_cidrs = optional(list(string), ["10.244.0.0/16"])
  })
}

variable "admin_group_object_ids" {
  description = "Entra ID groups whose members get the cluster-admin role. Only members of the listed groups can log in."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for id in var.admin_group_object_ids : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))])
    error_message = "Every group object ID must be a GUID."
  }
}

variable "viewer_group_object_ids" {
  description = "Entra ID groups whose members get the read-only view role in every namespace. Only members of the listed groups can log in."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for id in var.viewer_group_object_ids : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))])
    error_message = "Every group object ID must be a GUID."
  }
}

variable "kubectl_login" {
  description = <<-EOT
    Whether people can also log in with kubectl through the kubelogin plugin (kubectl oidc-login).
    When true, the app registration accepts the redirect addresses http://localhost:8000 and http://localhost:18000 as a public client. The kubectl_user_exec output shows the kubeconfig settings.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "claim_prefix" {
  description = "The prefix of Kubernetes user names and group names from Entra ID. With the default, the group 1234 becomes \"entra:1234\" in Kubernetes."
  type        = string
  default     = "entra:"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9.-]+:$", var.claim_prefix)) && !startswith(var.claim_prefix, "system:")
    error_message = "The claim_prefix value must end with a colon, use lowercase letters, digits, dots or hyphens, and must not be \"system:\"."
  }
}

variable "namespace" {
  description = "The namespace for Headlamp and oauth2-proxy."
  type        = string
  default     = "headlamp"
  nullable    = false
}

variable "app_display_name" {
  description = "The display name of the Entra ID app registration. Leave it empty to use \"Headlamp (<hostname>)\"."
  type        = string
  default     = null
}

variable "session" {
  description = <<-EOT
    The login session of oauth2-proxy.
    expire is how long a login lasts. refresh is how often oauth2-proxy gets a new ID token from Entra ID. Keep refresh below 60 minutes, because Entra ID tokens expire after 60 to 90 minutes.
  EOT
  type = object({
    expire  = optional(string, "8h")
    refresh = optional(string, "30m")
  })
  default  = {}
  nullable = false
}

variable "chart_versions" {
  description = "The Helm chart versions."
  type = object({
    headlamp     = optional(string, "0.46.0")
    oauth2_proxy = optional(string, "10.7.2")
  })
  default  = {}
  nullable = false
}
