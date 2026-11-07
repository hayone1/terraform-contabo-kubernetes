variable "cluster_name" {
  description = "The name of the cluster. The module uses the name for the default bucket name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,48}[a-z0-9])?$", var.cluster_name))
    error_message = "The cluster name must have 1 to 50 characters. It can only contain lowercase letters, digits and hyphens, and it must start and end with a letter or a digit."
  }
}

variable "issuer" {
  description = <<-EOT
    Where the service account issuer documents are published.

    mode = "object_storage" (the default) publishes the documents in a public bucket of a Contabo object storage.
    The issuer address is the public address of that bucket.

    mode = "external" only computes the documents. You publish them yourself at external_url.
    The "documents" output lists the object keys and the file contents.
  EOT
  type = object({
    mode = optional(string, "object_storage")

    object_storage = optional(object({
      object_storage_id     = string
      bucket_name           = optional(string)
      create_bucket         = optional(bool, true)
      cache_max_age_seconds = optional(number, 60)
    }))

    external_url = optional(string)
  })

  validation {
    condition     = contains(["object_storage", "external"], var.issuer.mode)
    error_message = "The issuer mode must be \"object_storage\" or \"external\"."
  }

  validation {
    condition     = var.issuer.mode != "object_storage" || var.issuer.object_storage != null
    error_message = "The issuer mode \"object_storage\" needs the issuer.object_storage settings."
  }

  validation {
    condition = (
      var.issuer.mode != "external" ||
      can(regex("^https://[^/?#]+(/[^?#]*[^/?#])?$", coalesce(var.issuer.external_url, "-")))
    )
    error_message = "The issuer mode \"external\" needs issuer.external_url. The address must start with https://, and it must not have a query, a fragment or a slash at the end."
  }

  validation {
    condition = (
      var.issuer.object_storage == null ||
      try(length(trimspace(var.issuer.object_storage.object_storage_id)) > 0, false)
    )
    error_message = "The issuer.object_storage.object_storage_id value must not be empty."
  }

  validation {
    condition = (
      var.issuer.object_storage == null ||
      try(var.issuer.object_storage.bucket_name, null) == null ||
      can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.issuer.object_storage.bucket_name))
    )
    error_message = "The bucket name must have 3 to 63 characters. It can only contain lowercase letters, digits and hyphens, and it must start and end with a letter or a digit."
  }

  validation {
    condition = (
      var.issuer.object_storage == null ||
      try(
        var.issuer.object_storage.cache_max_age_seconds >= 0 &&
        var.issuer.object_storage.cache_max_age_seconds <= 3600 &&
        floor(var.issuer.object_storage.cache_max_age_seconds) == var.issuer.object_storage.cache_max_age_seconds,
        false,
      )
    )
    error_message = "The cache_max_age_seconds value must be a whole number between 0 and 3600."
  }
}

variable "service_account_public_keys_pem" {
  description = <<-EOT
    The keys that the Kubernetes API server uses to check service account tokens, in PEM format.
    Pass the service account key from the Talos machine secrets. A private key is fine, because the module only uses its public part.
    During a key rotation, list the old key and the new key.
  EOT
  type        = list(string)
  sensitive   = true

  validation {
    condition     = length(var.service_account_public_keys_pem) > 0
    error_message = "At least one service account key is needed."
  }

  validation {
    condition     = alltrue([for key in var.service_account_public_keys_pem : strcontains(key, "-----BEGIN ")])
    error_message = "Every service account key must be in PEM format (text that starts with \"-----BEGIN \"). Talos stores the key base64-encoded, so pass it through base64decode()."
  }
}

variable "additional_accepted_issuers" {
  description = <<-EOT
    Older issuer addresses that the API server must still accept.
    Use this list only when you move a running cluster to a new issuer. Put the old issuer here, so that the tokens that pods already have stay valid.
    The API server signs new tokens with the main issuer only. Remove the old issuers after one day, when every pod has a new token.
  EOT
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for issuer in var.additional_accepted_issuers : can(regex("^https://[^/?#]+(/[^?#]*[^/?#])?$", issuer))])
    error_message = "Every older issuer must start with https://, and it must not have a query, a fragment or a slash at the end."
  }
}

variable "issuer_generation" {
  description = <<-EOT
    A number that protects the issuer address from accidental changes.
    The module stops with an error when the issuer address changes. To change the issuer on purpose, raise this number by one in the same change.
  EOT
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.issuer_generation >= 1 && floor(var.issuer_generation) == var.issuer_generation
    error_message = "The issuer_generation value must be a whole number of 1 or more."
  }
}

variable "kubernetes_api" {
  description = <<-EOT
    Optional access to the Kubernetes API server. When you set it, a check compares the key set that the API server serves with the key set that the module publishes.
    The check only warns. It never stops a plan, even when the API server cannot be reached.
  EOT
  type = object({
    url                    = string
    ca_certificate_pem     = string
    client_certificate_pem = string
    client_key_pem         = string
  })
  default   = null
  sensitive = true
}

variable "azure" {
  description = <<-EOT
    Settings for Microsoft Entra ID (Azure) workload identity.
    When enabled is true, the module renders the Azure workload identity webhook, which gives pods an Entra ID token file.
    kubernetes_version is the version that Helm uses to render the webhook chart, for example "1.36.6". Leave it empty to use the default of Helm.
  EOT
  type = object({
    enabled               = optional(bool, false)
    tenant_id             = optional(string)
    webhook_chart_version = optional(string, "1.6.1")
    webhook_namespace     = optional(string, "azure-workload-identity-system")
    webhook_helm_values   = optional(any, {})
    kubernetes_version    = optional(string)
  })
  default  = {}
  nullable = false

  validation {
    condition = (
      !var.azure.enabled ||
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", coalesce(var.azure.tenant_id, "-")))
    )
    error_message = "Azure workload identity needs azure.tenant_id, which must be a GUID."
  }

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.azure.webhook_namespace))
    error_message = "The azure.webhook_namespace value must be a valid Kubernetes namespace name."
  }

  validation {
    condition     = var.azure.kubernetes_version == null || can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+$", coalesce(var.azure.kubernetes_version, "-")))
    error_message = "The azure.kubernetes_version value must look like \"1.36.6\"."
  }
}
