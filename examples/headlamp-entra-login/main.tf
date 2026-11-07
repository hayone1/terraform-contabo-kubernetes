# The Kubernetes side.
#
# Browser -> ingress -> oauth2-proxy -> Headlamp -> Kubernetes API server
#
# oauth2-proxy logs the person in with Entra ID and sends the person's ID token
# to Headlamp in the X-Forwarded-Id-Token header. Headlamp sends the token to
# the API server, which checks it (authentication.tf) and applies RBAC to the
# person. Headlamp's own service account has no permissions.

locals {
  headlamp_service = "headlamp"
  tls_secret_name  = "headlamp-tls"

  # Every header that Headlamp trusts is set by oauth2-proxy. oauth2-proxy
  # removes a header with the same name that a client sends, so a client
  # cannot pretend to be somebody else.
  injected_headers = {
    "X-Forwarded-User"     = "preferred_username"
    "X-Forwarded-Email"    = "email"
    "X-Forwarded-Group"    = "groups"
    "X-Forwarded-Id-Token" = "id_token"
  }

  oauth2_proxy_alpha_config = {
    providers = [
      {
        id                    = "entra"
        provider              = "entra-id"
        clientID              = azuread_application.headlamp.client_id
        scope                 = join(" ", ["openid", "profile", "email", "offline_access"])
        code_challenge_method = "S256"
        oidcConfig = {
          issuerURL = local.entra_issuer
          # Entra ID does not send email_verified. Access is limited by the
          # group assignment of the app, not by the email address.
          insecureAllowUnverifiedEmail = true
          emailClaim                   = "preferred_username"
          # The object ID is always in the token and never changes.
          userIDClaim    = "oid"
          groupsClaim    = "groups"
          audienceClaims = ["aud"]
        }
        microsoftEntraIDConfig = {
          federatedTokenAuth = true
        }
      },
    ]
    upstreamConfig = {
      upstreams = [
        {
          id              = "headlamp"
          path            = "/"
          uri             = "http://${local.headlamp_service}.${var.namespace}.svc.cluster.local:80"
          passHostHeader  = true
          proxyWebSockets = true
          flushInterval   = "1s"
        },
      ]
    }
    injectRequestHeaders = [
      for name, claim in local.injected_headers : {
        name   = name
        values = [{ claimSource = { claim = claim } }]
      }
    ]
  }
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }

  # Other tools write annotations on namespaces. Rancher, for example, adds
  # cattle.io annotations to every namespace.
  lifecycle {
    ignore_changes = [metadata[0].annotations]
  }
}

# oauth2-proxy needs a secret of exactly 16, 24 or 32 bytes. 32 letters and
# digits are 32 bytes. Standard base64 text would not work, because
# oauth2-proxy only decodes the URL-safe base64 alphabet.
resource "random_password" "cookie_secret" {
  length  = 32
  special = false
}

resource "helm_release" "headlamp" {
  name = "headlamp"
  # Repairs a release that a failed apply left behind.
  upgrade_install = true
  namespace       = kubernetes_namespace_v1.this.metadata[0].name
  repository      = "https://kubernetes-sigs.github.io/headlamp/"
  chart           = "headlamp"
  version         = var.chart_versions.headlamp
  wait            = true
  timeout         = 600

  values = [yamlencode({
    fullnameOverride = local.headlamp_service
    config = {
      inCluster = true
      # Trust the identity headers of oauth2-proxy. The default header names
      # match local.injected_headers.
      extraArgs = ["-proxy-auth=true"]
    }
    # Headlamp acts with the token of the person, never with its own account.
    clusterRoleBinding = {
      create = false
    }
    podSecurityContext = {
      runAsNonRoot   = true
      seccompProfile = { type = "RuntimeDefault" }
    }
    securityContext = {
      allowPrivilegeEscalation = false
      capabilities             = { drop = ["ALL"] }
      readOnlyRootFilesystem   = true
      runAsNonRoot             = true
      runAsUser                = 100
      runAsGroup               = 101
    }
  })]
}

resource "helm_release" "oauth2_proxy" {
  name = "oauth2-proxy"
  # Repairs a release that a failed apply left behind.
  upgrade_install = true
  namespace       = kubernetes_namespace_v1.this.metadata[0].name
  repository      = "https://oauth2-proxy.github.io/manifests"
  chart           = "oauth2-proxy"
  version         = var.chart_versions.oauth2_proxy
  wait            = true
  timeout         = 600

  values = [yamlencode({
    fullnameOverride = "oauth2-proxy"

    config = {
      clientID     = azuread_application.headlamp.client_id
      cookieSecret = random_password.cookie_secret.result
      # Workload identity replaces the client secret.
      requiredSecretKeys = ["client-id", "cookie-secret"]
      configFile = join("\n", [
        "email_domains = [\"*\"]",
        "redirect_url = \"https://${var.hostname}/oauth2/callback\"",
        "reverse_proxy = true",
        # Only the ingress controller may set X-Forwarded-* headers.
        "trusted_proxy_ips = ${jsonencode(var.ingress.trusted_proxy_cidrs)}",
        "skip_provider_button = true",
        "cookie_name = \"_headlamp_auth\"",
        "cookie_secure = true",
        "cookie_samesite = \"lax\"",
        "cookie_expire = \"${var.session.expire}\"",
        "cookie_refresh = \"${var.session.refresh}\"",
      ])
    }

    alphaConfig = {
      enabled    = true
      configData = local.oauth2_proxy_alpha_config
    }

    serviceAccount = {
      enabled = true
      name    = local.oauth2_proxy_service_account
      annotations = {
        "azure.workload.identity/client-id" = azuread_application.headlamp.client_id
      }
    }

    podLabels = {
      "azure.workload.identity/use" = "true"
    }

    podSecurityContext = {
      runAsNonRoot   = true
      seccompProfile = { type = "RuntimeDefault" }
    }

    ingress = {
      enabled     = true
      className   = var.ingress.class_name
      path        = "/"
      pathType    = "Prefix"
      hosts       = [var.hostname]
      annotations = merge(var.ingress.cluster_issuer == null ? {} : { "cert-manager.io/cluster-issuer" = var.ingress.cluster_issuer }, var.ingress.annotations)
      tls = [{
        secretName = local.tls_secret_name
        hosts      = [var.hostname]
      }]
    }
  })]

  # The token exchange fails until Entra ID knows the federated credential.
  depends_on = [
    azuread_application_federated_identity_credential.oauth2_proxy,
    azuread_service_principal_delegated_permission_grant.login,
    helm_release.headlamp,
  ]
}

# Only oauth2-proxy may talk to Headlamp. Your network plugin must enforce
# network policies (Cilium does; plain Flannel does not).
resource "kubernetes_network_policy_v1" "headlamp" {
  metadata {
    name      = "headlamp-from-oauth2-proxy"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name"     = "headlamp"
        "app.kubernetes.io/instance" = helm_release.headlamp.name
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "oauth2-proxy"
          }
        }
      }
      ports {
        port     = "4466"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_cluster_role_binding_v1" "admins" {
  for_each = toset(var.admin_group_object_ids)

  metadata {
    name = "entra-cluster-admin-${each.value}"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "${var.claim_prefix}${each.value}"
  }
}

resource "kubernetes_cluster_role_binding_v1" "viewers" {
  for_each = toset(var.viewer_group_object_ids)

  metadata {
    name = "entra-view-${each.value}"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "${var.claim_prefix}${each.value}"
  }
}
