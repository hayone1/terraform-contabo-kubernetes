output "issuer_url" {
  description = "The service account issuer address. Cloud providers trust tokens with this issuer."
  value       = local.issuer_url

  precondition {
    condition     = local.issuer_unchanged
    error_message = local.issuer_changed_message
  }
  precondition {
    condition     = local.location_unchanged
    error_message = local.location_changed_message
  }
}

output "jwks_uri" {
  description = "The address of the published key set."
  value       = local.jwks_uri
}

output "kube_apiserver_extra_args" {
  description = <<-EOT
    Extra arguments for the Kubernetes API server, for Kubernetes distributions other than Talos 1.14 and newer.
    With additional_accepted_issuers, the values of service-account-issuer and api-audiences are lists. Each list item becomes one repeated flag, so the distribution must accept repeated flags.
  EOT
  value       = local.kube_apiserver_extra_args

  precondition {
    condition     = local.issuer_unchanged
    error_message = local.issuer_changed_message
  }
  precondition {
    condition     = local.location_unchanged
    error_message = local.location_changed_message
  }
}

output "inline_manifests" {
  description = "The Kubernetes manifests of the cloud integration as a list of objects with a name and the manifest text. talos_config_patch already contains them. The list is empty when no cloud integration is enabled."
  value       = local.inline_manifests
}

output "talos_config_patch" {
  description = <<-EOT
    A Talos machine configuration patch for control plane nodes, for Talos 1.14 and newer.
    The patch has several YAML documents: KubeServiceAccountConfig sets the issuer, KubeAPIServerConfig sets the key set address, and one KubeInlineManifestConfig document per manifest adds the cloud integration.
  EOT
  value = join("\n---\n", concat(
    [
      yamlencode(merge(
        {
          apiVersion = "v1alpha1"
          kind       = "KubeServiceAccountConfig"
          issuer     = { issuerURL = local.issuer_url }
        },
        # Tokens from before a move carry the old issuer as their audience.
        # Without the old audiences, the API server refuses those tokens until
        # kubelet renews them.
        local.migrating ? { accepted = { issuers = local.old_issuers, audiences = local.accepted_issuers } } : {},
      )),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeAPIServerConfig"
        extraArgs  = { "service-account-jwks-uri" = local.jwks_uri }
      }),
    ],
    [for manifest in local.inline_manifests : yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeInlineManifestConfig"
      name       = manifest.name
      manifest   = manifest.contents
    })],
  ))

  precondition {
    condition     = local.issuer_unchanged
    error_message = local.issuer_changed_message
  }
  precondition {
    condition     = local.location_unchanged
    error_message = local.location_changed_message
  }
}

output "openid_configuration" {
  description = "The discovery document (JSON) that is published at <issuer>/.well-known/openid-configuration."
  value       = data.contabo_kubernetes_oidc_documents.this.openid_configuration
}

output "jwks" {
  description = "The key set (JSON) that is published at the jwks_uri address."
  value       = data.contabo_kubernetes_oidc_documents.this.jwks
}

output "key_ids" {
  description = "The key ids in the key set."
  value       = data.contabo_kubernetes_oidc_documents.this.key_ids
}

output "bucket_name" {
  description = "The bucket that holds the documents, or null when the issuer mode is external."
  value       = local.bucket_name
}

output "azure" {
  description = "Values for Entra ID federated identity credentials, or null when Azure is not enabled."
  value = local.azure_enabled ? {
    tenant_id         = var.azure.tenant_id
    issuer            = local.issuer_url
    audience          = "api://AzureADTokenExchange"
    subject_format    = "system:serviceaccount:<namespace>:<service account name>"
    webhook_namespace = var.azure.webhook_namespace
  } : null
}

output "inline_manifests_sha256" {
  description = <<-EOT
    A checksum of all inline manifests, or null when no cloud integration is enabled.
    Talos does not apply a changed inline manifest to a running cluster. Use this value as a trigger for "talosctl upgrade-k8s --to <current Kubernetes version>", which applies the stored manifests. The README shows an example.
  EOT
  value       = length(local.inline_manifests) > 0 ? sha256(jsonencode(local.inline_manifests)) : null
}

output "documents" {
  description = <<-EOT
    The issuer documents as a map from the object key (the path below the issuer address) to the file content.
    Use this output with issuer mode "external" to publish the documents yourself. Serve both files with the header "Content-Type: application/json".
  EOT
  value       = { for document in local.documents : document.key => document.content }
}
