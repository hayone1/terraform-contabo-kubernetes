# These checks only warn. A failed check never stops a plan or an apply.

# Reads the published documents through the public address, the same way
# Entra ID reads them. Right after the first apply, the cache in front of the
# bucket can still hold an older answer for up to cache_max_age_seconds.
check "published_discovery_document" {
  data "http" "discovery" {
    url = "${local.issuer_url}/.well-known/openid-configuration"
  }

  assert {
    condition = (
      data.http.discovery.status_code == 200 &&
      try(jsondecode(data.http.discovery.response_body) == jsondecode(data.contabo_kubernetes_oidc_documents.this.openid_configuration), false)
    )
    error_message = "The discovery document at ${local.issuer_url}/.well-known/openid-configuration is missing or out of date (HTTP ${data.http.discovery.status_code}). Cloud logins of the cluster fail until the document is correct. Right after an apply, wait for the cache time and run the plan again."
  }
}

check "published_jwks" {
  data "http" "jwks" {
    url = local.jwks_uri
  }

  assert {
    condition = (
      data.http.jwks.status_code == 200 &&
      try(jsondecode(data.http.jwks.response_body) == jsondecode(data.contabo_kubernetes_oidc_documents.this.jwks), false)
    )
    error_message = "The key set at ${local.jwks_uri} is missing or out of date (HTTP ${data.http.jwks.status_code}). Cloud providers cannot check new tokens until the key set is correct."
  }
}

# Compares the key set that the API server serves with the published key set.
# A difference means that the API server signs tokens with a key that the
# module does not know, for example after a change of the service account key.
# Without kubernetes_api, the check reads the public key set and always passes.
check "api_server_jwks" {
  data "http" "api_jwks" {
    url             = var.kubernetes_api != null ? "${trimsuffix(var.kubernetes_api.url, "/")}/openid/v1/jwks" : local.jwks_uri
    ca_cert_pem     = try(var.kubernetes_api.ca_certificate_pem, null)
    client_cert_pem = try(var.kubernetes_api.client_certificate_pem, null)
    client_key_pem  = try(var.kubernetes_api.client_key_pem, null)
  }

  assert {
    condition = (
      var.kubernetes_api == null || (
        data.http.api_jwks.status_code == 200 &&
        try(jsondecode(data.http.api_jwks.response_body) == jsondecode(data.contabo_kubernetes_oidc_documents.this.jwks), false)
      )
    )
    error_message = "The API server answered HTTP ${data.http.api_jwks.status_code} for its key set, or it serves a different key set than the one the module publishes. Pass every service account key of the cluster in service_account_public_keys_pem."
  }
}
