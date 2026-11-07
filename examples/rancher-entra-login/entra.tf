# The Entra ID side: two app registrations.
#
# "rancher" is the app that people log in to. Rancher reads users and groups
# with it. Rancher only supports a client secret for this app.
#
# "rotator" has no secret at all. A job in the cluster logs in as "rotator"
# with its Kubernetes service account token (workload identity), creates a
# short-lived client secret on "rancher", and hands it to Rancher. "rotator"
# may only change apps that it owns, and it owns only "rancher".

data "azuread_client_config" "current" {}

data "azuread_application_published_app_ids" "well_known" {}

data "azuread_service_principal" "msgraph" {
  client_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
}

locals {
  graph_app_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
  login_groups = distinct(concat(var.admin_group_object_ids, var.user_group_object_ids))

  # Rancher looks up users, groups and group memberships with these
  # application permissions (Rancher documentation, Microsoft Entra ID).
  rancher_graph_roles = ["User.Read.All", "GroupMember.Read.All"]

  rotator_service_account = "entra-secret-rotator"
}

resource "azuread_application" "rancher" {
  display_name     = "Rancher (${var.hostname})"
  sign_in_audience = "AzureADMyOrg"
  # Application.ReadWrite.OwnedBy only covers apps that the rotator owns, so
  # the rotator is an owner. The owner list must stay in this block: the
  # resource removes every owner that the list does not name.
  owners = [data.azuread_client_config.current.object_id, azuread_service_principal.rotator.object_id]

  web {
    redirect_uris = ["https://${var.hostname}/verify-auth-azure"]

    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  required_resource_access {
    resource_app_id = local.graph_app_id

    dynamic "resource_access" {
      for_each = local.rancher_graph_roles
      content {
        id   = data.azuread_service_principal.msgraph.app_role_ids[resource_access.value]
        type = "Role"
      }
    }
  }

  # The rotator adds and removes secrets. Terraform must not remove them.
  lifecycle {
    ignore_changes = [password]
  }
}

resource "azuread_service_principal" "rancher" {
  client_id = azuread_application.rancher.client_id
  owners    = [data.azuread_client_config.current.object_id]

  # Only members of assigned groups can log in.
  app_role_assignment_required = true
}

resource "azuread_app_role_assignment" "rancher_login" {
  for_each = toset(local.login_groups)

  app_role_id         = "00000000-0000-0000-0000-000000000000"
  principal_object_id = each.value
  resource_object_id  = azuread_service_principal.rancher.object_id
}

# Admin consent for the Graph application permissions of Rancher.
resource "azuread_app_role_assignment" "rancher_graph" {
  for_each = toset(local.rancher_graph_roles)

  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids[each.value]
  principal_object_id = azuread_service_principal.rancher.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

resource "azuread_application" "rotator" {
  display_name     = "Rancher secret rotator (${var.hostname})"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]

  required_resource_access {
    resource_app_id = local.graph_app_id

    resource_access {
      id   = data.azuread_service_principal.msgraph.app_role_ids["Application.ReadWrite.OwnedBy"]
      type = "Role"
    }
  }
}

resource "azuread_service_principal" "rotator" {
  client_id = azuread_application.rotator.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_app_role_assignment" "rotator_graph" {
  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids["Application.ReadWrite.OwnedBy"]
  principal_object_id = azuread_service_principal.rotator.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

resource "azuread_application_federated_identity_credential" "rotator" {
  application_id = azuread_application.rotator.id
  display_name   = "rotator-${replace(var.hostname, ".", "-")}"
  description    = "The secret rotation job in ${var.secret_rotation.namespace} logs in with its Kubernetes service account token."
  issuer         = var.issuer_url
  subject        = "system:serviceaccount:${var.secret_rotation.namespace}:${local.rotator_service_account}"
  audiences      = ["api://AzureADTokenExchange"]
}
