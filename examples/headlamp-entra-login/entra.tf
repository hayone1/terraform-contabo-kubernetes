# The Entra ID side: one app registration that people log in to.
#
# oauth2-proxy proves its identity to Entra ID with its Kubernetes service
# account token (workload identity). The app registration therefore has a
# federated credential and no client secret.

data "azuread_client_config" "current" {}

data "azuread_application_published_app_ids" "well_known" {}

data "azuread_service_principal" "msgraph" {
  client_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
}

locals {
  app_display_name = coalesce(var.app_display_name, "Headlamp (${var.hostname})")
  login_groups     = distinct(concat(var.admin_group_object_ids, var.viewer_group_object_ids))

  # oauth2-proxy runs with this service account. The federated credential
  # trusts tokens of exactly this account.
  oauth2_proxy_service_account = "oauth2-proxy"

  # Delegated permissions for the login. Admin consent is granted below, so
  # people never see a consent prompt.
  login_scopes = ["openid", "profile", "email", "offline_access", "User.Read"]
}

resource "azuread_application" "headlamp" {
  display_name     = local.app_display_name
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]

  # Put only the groups that are assigned to the app into the ID token. This
  # keeps the token small and avoids the 200-group limit of Entra ID.
  group_membership_claims = ["ApplicationGroup"]

  # kubelogin logs in through the browser and the localhost redirect
  # addresses below. That flow needs no fallback to a public client. The
  # fallback would also allow password and device code logins.
  fallback_public_client_enabled = false

  # No api block: access tokens for this app keep version 1, and their issuer
  # (https://sts.windows.net/<tenant>/) does not match the authenticator of
  # the API server. The API server therefore only accepts ID tokens.

  web {
    redirect_uris = ["https://${var.hostname}/oauth2/callback"]

    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  dynamic "public_client" {
    for_each = var.kubectl_login ? [1] : []
    content {
      redirect_uris = ["http://localhost:8000/", "http://localhost:18000/"]
    }
  }

  optional_claims {
    id_token {
      name = "email"
    }
    # Marks app-only tokens with idtyp=app, so that the API server can refuse
    # them (authentication.tf). Only people may log in.
    access_token {
      name = "idtyp"
    }
  }

  required_resource_access {
    resource_app_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]

    dynamic "resource_access" {
      for_each = local.login_scopes
      content {
        id   = data.azuread_service_principal.msgraph.oauth2_permission_scope_ids[resource_access.value]
        type = "Scope"
      }
    }
  }
}

resource "azuread_service_principal" "headlamp" {
  client_id = azuread_application.headlamp.client_id
  owners    = [data.azuread_client_config.current.object_id]

  # Only assigned groups can log in. Everybody else gets an error from
  # Entra ID before Headlamp sees a request.
  app_role_assignment_required = true

  lifecycle {
    precondition {
      condition     = length(local.login_groups) > 0
      error_message = "Set admin_group_object_ids or viewer_group_object_ids. Without a group, nobody can log in."
    }
  }
}

resource "azuread_app_role_assignment" "login" {
  for_each = toset(local.login_groups)

  # The all-zero ID is the default access role of every app.
  app_role_id         = "00000000-0000-0000-0000-000000000000"
  principal_object_id = each.value
  resource_object_id  = azuread_service_principal.headlamp.object_id
}

resource "azuread_service_principal_delegated_permission_grant" "login" {
  service_principal_object_id          = azuread_service_principal.headlamp.object_id
  resource_service_principal_object_id = data.azuread_service_principal.msgraph.object_id
  claim_values                         = local.login_scopes
}

resource "azuread_application_federated_identity_credential" "oauth2_proxy" {
  application_id = azuread_application.headlamp.id
  display_name   = "oauth2-proxy-${replace(var.hostname, ".", "-")}"
  description    = "oauth2-proxy in ${var.namespace} logs in with its Kubernetes service account token."
  issuer         = var.issuer_url
  subject        = "system:serviceaccount:${var.namespace}:${local.oauth2_proxy_service_account}"
  audiences      = ["api://AzureADTokenExchange"]
}
