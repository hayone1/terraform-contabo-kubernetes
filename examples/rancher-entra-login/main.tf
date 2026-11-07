# The Kubernetes side: Rancher, and a small chart that turns on the Entra ID
# login and keeps the client secret of Rancher fresh.

locals {
  rancher_url        = "https://${var.hostname}"
  admin_principals   = [for id in var.admin_group_object_ids : "azuread_group://${id}"]
  user_principals    = [for id in var.user_group_object_ids : "azuread_group://${id}"]
  ingress_annotation = var.ingress.cluster_issuer == null ? {} : { "cert-manager.io/cluster-issuer" = var.ingress.cluster_issuer }

  # The helm provider only looks at the chart version and the values. The
  # checksum makes every change of the local chart, for example of rotate.sh,
  # an upgrade of the release, which also runs the install job again.
  chart_dir = "${path.module}/charts/rancher-entra-auth"
  # Line endings are removed first, so a Windows checkout gives the same value.
  chart_checksum = sha256(join("", [for file in sort(fileset(local.chart_dir, "**")) : sha256(replace(file("${local.chart_dir}/${file}"), "\r", ""))]))
}

# The local administrator "admin" stays as an emergency login. Keep the
# password in a password manager, and change it after the first login.
resource "random_password" "bootstrap" {
  length  = 24
  special = false
}

resource "helm_release" "rancher" {
  name = "rancher"
  # Repairs a release that a failed apply left behind.
  upgrade_install  = true
  namespace        = "cattle-system"
  create_namespace = true
  repository       = "https://releases.rancher.com/server-charts/stable"
  chart            = "rancher"
  version          = var.rancher.chart_version
  wait             = true
  timeout          = 1200

  values = [
    yamlencode({
      hostname          = var.hostname
      replicas          = var.rancher.replicas
      bootstrapPassword = random_password.bootstrap.result
      # The certificate comes from cert-manager (or from you) and is publicly
      # trusted, so agents use the system trust store.
      agentTLSMode = "system-store"
      privateCA    = false
      ingress = {
        ingressClassName               = var.ingress.class_name
        includeDefaultExtraAnnotations = false
        extraAnnotations               = merge(local.ingress_annotation, var.ingress.annotations)
        tls = {
          source     = "secret"
          secretName = "tls-rancher-ingress"
        }
      }
    }),
    yamlencode(var.rancher.helm_values),
  ]
}

resource "helm_release" "entra_auth" {
  name = "rancher-entra-auth"
  # Repairs a release that a failed apply left behind.
  upgrade_install = true
  # Adopts the Secret azureadconfig-applicationsecret when somebody turned on
  # the Entra ID login in the Rancher user interface before.
  take_ownership   = true
  namespace        = var.secret_rotation.namespace
  create_namespace = true
  chart            = local.chart_dir
  wait             = true
  timeout          = 1800

  values = [yamlencode({
    rotatorClientId    = azuread_application.rotator.client_id
    chartChecksum      = local.chart_checksum
    tenantId           = lower(var.tenant_id)
    serviceAccountName = local.rotator_service_account
    rancherClientId    = azuread_application.rancher.client_id
    rancherUrl         = local.rancher_url
    adminPrincipals    = local.admin_principals
    userPrincipals     = local.user_principals
    schedule           = var.secret_rotation.schedule
    image              = var.secret_rotation.image
    secret = {
      # A fixed name: the job finds its own secrets by this name, also after
      # a change of the host name.
      displayName     = "rancher-entra-auth"
      lifetimeDays    = var.secret_rotation.lifetime_days
      renewBeforeDays = var.secret_rotation.renew_before_days
    }
  })]

  depends_on = [
    helm_release.rancher,
    azuread_application_federated_identity_credential.rotator,
    azuread_app_role_assignment.rotator_graph,
    azuread_app_role_assignment.rancher_graph,
    azuread_app_role_assignment.rancher_login,
  ]
}
