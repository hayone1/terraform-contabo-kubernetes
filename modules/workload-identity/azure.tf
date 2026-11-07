locals {
  azure_enabled = var.azure.enabled

  azure_namespace_manifest = local.azure_enabled ? yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = var.azure.webhook_namespace
    }
  }) : null
}

# The webhook adds the Entra ID token file and the AZURE_* variables to pods
# that have the label azure.workload.identity/use=true and a service account
# with the annotation azure.workload.identity/client-id.
data "helm_template" "azure_webhook" {
  count = local.azure_enabled ? 1 : 0

  name         = "workload-identity-webhook"
  namespace    = var.azure.webhook_namespace
  repository   = "https://azure.github.io/azure-workload-identity/charts"
  chart        = "workload-identity-webhook"
  version      = var.azure.webhook_chart_version
  kube_version = var.azure.kubernetes_version

  values = [
    yamlencode({ azureTenantID = var.azure.tenant_id }),
    yamlencode(var.azure.webhook_helm_values),
  ]
}

locals {
  inline_manifests = local.azure_enabled ? [
    {
      name     = "azure-workload-identity-webhook"
      contents = join("\n---\n", [local.azure_namespace_manifest, data.helm_template.azure_webhook[0].manifest])
    }
  ] : []
}
