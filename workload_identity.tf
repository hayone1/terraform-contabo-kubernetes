module "workload_identity" {
  source = "./modules/workload-identity"
  count  = var.workload_identity.enabled ? 1 : 0

  cluster_name = var.cluster_name
  issuer       = var.workload_identity.issuer

  # Talos keeps the service account key base64-encoded. The module derives the
  # public key from it.
  service_account_public_keys_pem = [base64decode(talos_machine_secrets.this.machine_secrets.certs.k8s_serviceaccount.key)]

  issuer_generation           = var.workload_identity.issuer_generation
  additional_accepted_issuers = var.workload_identity.additional_accepted_issuers

  # A check in the module compares the keys that the API server serves with
  # the published keys. The check only warns.
  kubernetes_api = {
    url                    = local.kubernetes_api_url
    ca_certificate_pem     = base64decode(local.kubernetes_client.ca_certificate)
    client_certificate_pem = base64decode(local.kubernetes_client.client_certificate)
    client_key_pem         = base64decode(local.kubernetes_client.client_key)
  }

  # A null value takes the default of the module.
  azure = {
    enabled               = var.workload_identity.azure != null
    tenant_id             = try(var.workload_identity.azure.tenant_id, null)
    webhook_chart_version = try(var.workload_identity.azure.webhook_chart_version, null)
    webhook_namespace     = try(var.workload_identity.azure.webhook_namespace, null)
    webhook_helm_values   = try(var.workload_identity.azure.webhook_helm_values, null)
    kubernetes_version    = var.kubernetes_version
  }
}
