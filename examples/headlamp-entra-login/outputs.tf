output "url" {
  description = "The address of Headlamp."
  value       = "https://${var.hostname}"
}

output "client_id" {
  description = "The client ID of the Entra ID app registration. Kubernetes uses it as the token audience."
  value       = azuread_application.headlamp.client_id
}

output "talos_config_patch" {
  description = <<-EOT
    A Talos 1.14 patch for the control plane nodes. It makes the API server trust the ID tokens of the app registration.
    Talos replaces its whole authentication configuration with this document. If you already have other JWT authenticators, merge them with the jwt_authenticator output instead.
  EOT
  value = yamlencode({
    apiVersion    = "v1alpha1"
    kind          = "KubeAuthenticationConfig"
    configuration = local.authentication_configuration
  })
}

output "jwt_authenticator" {
  description = "The JWT authenticator for Entra ID as an object, for clusters that already have an authentication configuration."
  value       = local.jwt_authenticator
}

output "authentication_configuration_yaml" {
  description = "A complete AuthenticationConfiguration file for Kubernetes distributions other than Talos (kube-apiserver --authentication-config)."
  value = yamlencode(merge(
    {
      apiVersion = "apiserver.config.k8s.io/v1"
      kind       = "AuthenticationConfiguration"
    },
    local.authentication_configuration,
  ))
}

output "kubectl_user_exec" {
  description = "The kubeconfig user entry for kubectl with the kubelogin plugin, or null when kubectl_login is false."
  value = var.kubectl_login ? {
    apiVersion = "client.authentication.k8s.io/v1"
    command    = "kubectl"
    args = [
      "oidc-login",
      "get-token",
      "--oidc-issuer-url=${local.entra_issuer}",
      "--oidc-client-id=${azuread_application.headlamp.client_id}",
      "--oidc-extra-scope=profile",
      "--oidc-extra-scope=offline_access",
      "--oidc-pkce-method=S256",
    ]
    interactiveMode = "IfAvailable"
  } : null
}
