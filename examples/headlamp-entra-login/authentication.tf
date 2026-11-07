# The Kubernetes API server must trust the ID tokens that Entra ID issues for
# the app registration. This file renders that trust as structured
# authentication configuration (Kubernetes 1.34 and newer).
#
# The example cannot change the API server by itself, because the control
# plane configuration belongs to the configuration that builds the cluster.
# Add the talos_config_patch output to the control plane nodes.

locals {
  # Entra ID writes the tenant ID in lowercase into every token.
  tenant_id    = lower(var.tenant_id)
  entra_issuer = "https://login.microsoftonline.com/${local.tenant_id}/v2.0"

  jwt_authenticator = {
    issuer = {
      url                 = local.entra_issuer
      audiences           = [azuread_application.headlamp.client_id]
      audienceMatchPolicy = "MatchAny"
    }
    claimValidationRules = [
      {
        expression = "claims.tid == '${local.tenant_id}'"
        message    = "The token was issued for another Entra ID tenant."
      },
      {
        # An app (for example oauth2-proxy with its federated credential) can
        # get a token for the app registration. Such a token is not a person.
        expression = "!has(claims.idtyp) || claims.idtyp != 'app'"
        message    = "App-only tokens are not accepted. Log in as a person."
      },
    ]
    claimMappings = {
      # The object ID never changes and is unique in the tenant. Names and
      # email addresses can change, so RBAC must not depend on them.
      username = { expression = "'${var.claim_prefix}' + claims.oid" }
      uid      = { expression = "claims.oid" }
      # claims.groups has the CEL type "any". dyn() makes the list usable in
      # map(); without it, kube-apiserver refuses the configuration and stops.
      groups = { expression = "has(claims.groups) ? dyn(claims.groups).map(g, '${var.claim_prefix}' + string(g)) : []" }
      extra = [
        {
          key             = "entra.microsoft.com/preferred-username"
          valueExpression = "has(claims.preferred_username) ? claims.preferred_username : ''"
        },
      ]
    }
    userValidationRules = [
      {
        expression = "!user.username.startsWith('system:')"
        message    = "User names that start with system: are reserved for Kubernetes."
      },
    ]
  }

  # Talos replaces its own default configuration with this one, so the
  # anonymous health checks of the default are listed again.
  authentication_configuration = {
    anonymous = {
      enabled = true
      conditions = [
        { path = "/livez" },
        { path = "/readyz" },
        { path = "/healthz" },
      ]
    }
    jwt = [local.jwt_authenticator]
  }
}
