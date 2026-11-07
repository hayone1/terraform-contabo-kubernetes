# Ingress with the Gateway API of Cilium, certificates from cert-manager and
# DNS records from external-dns. cert-manager and external-dns use the Contabo
# DNS API through the webhooks of the user (hayone1/cert-manager-webhook-contabo
# and hayone1/external-dns-contabo-webhook).

locals {
  gateway_enabled = var.gateway_api.enabled

  # The Gateway listens on ports 80 and 443 of the ingress nodes.
  public_ports = distinct(concat(var.public_ports, local.gateway_enabled ? [80, 443] : []))

  # Talos sets this label on the ingress nodes. Envoy of Cilium listens only on
  # nodes with the label.
  ingress_label = "node.kubernetes.io/ingress"

  ingress_public_ipv4 = [for key in local.ingress_keys : local.public_ipv4[key]]

  # A shared Gateway for the domain, with a wildcard certificate.
  shared_gateway = local.gateway_enabled && var.gateway_api.domain != null && var.cert_manager.enabled

  external_dns_domains = coalesce(var.external_dns.domain_filters, compact([var.gateway_api.domain]))

  dns_credentials_secret = {
    for namespace in compact([
      var.cert_manager.enabled ? "cert-manager" : "",
      var.external_dns.enabled ? "external-dns" : "",
      ]) : namespace => yamlencode({
      apiVersion = "v1"
      kind       = "Secret"
      metadata   = { name = "contabo-credentials", namespace = namespace }
      type       = "Opaque"
      stringData = var.contabo_dns_credentials == null ? {} : {
        "client-id"     = var.contabo_dns_credentials.client_id
        "client-secret" = var.contabo_dns_credentials.client_secret
        "api-user"      = var.contabo_dns_credentials.api_user
        "api-password"  = var.contabo_dns_credentials.api_password
      }
    })
  }
}

data "http" "gateway_api_crds" {
  count = local.gateway_enabled ? 1 : 0

  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api.crds_version}/standard-install.yaml"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "The Gateway API CRDs ${var.gateway_api.crds_version} could not be downloaded (HTTP ${self.status_code})."
    }
  }
}

data "helm_template" "cert_manager" {
  count = var.cert_manager.enabled ? 1 : 0

  name         = "cert-manager"
  namespace    = "cert-manager"
  repository   = "https://charts.jetstack.io"
  chart        = "cert-manager"
  version      = var.cert_manager.chart_version
  kube_version = var.kubernetes_version

  values = [
    yamlencode({
      crds = { enabled = true, keep = true }
      # Helm hooks never run in inline manifests.
      startupapicheck = { enabled = false }
      # Public resolvers see the challenge records. The Contabo name servers
      # answer for the zone.
      dns01RecursiveNameservers     = "1.1.1.1:53,8.8.8.8:53"
      dns01RecursiveNameserversOnly = true
    }),
    yamlencode(var.cert_manager.helm_values),
  ]
}

data "helm_template" "cert_manager_webhook" {
  count = var.cert_manager.enabled ? 1 : 0

  name         = "cert-manager-webhook-contabo"
  namespace    = "cert-manager"
  repository   = "oci://ghcr.io/hayone1/charts"
  chart        = "cert-manager-webhook-contabo"
  version      = var.cert_manager.webhook_chart_version
  kube_version = var.kubernetes_version

  values = [yamlencode(var.cert_manager.webhook_helm_values)]
}

data "helm_template" "external_dns" {
  count = var.external_dns.enabled ? 1 : 0

  name         = "external-dns"
  namespace    = "external-dns"
  repository   = "https://kubernetes-sigs.github.io/external-dns"
  chart        = "external-dns"
  version      = var.external_dns.chart_version
  kube_version = var.kubernetes_version

  values = [
    yamlencode({
      provider = {
        name = "webhook"
        webhook = {
          image = {
            repository = "ghcr.io/hayone1/external-dns-contabo-webhook"
            tag        = var.external_dns.webhook_version
          }
          env = concat(
            [for name, key in {
              CONTABO_CLIENT_ID     = "client-id"
              CONTABO_CLIENT_SECRET = "client-secret"
              CONTABO_API_USER      = "api-user"
              CONTABO_API_PASSWORD  = "api-password"
              } : {
              name      = name
              valueFrom = { secretKeyRef = { name = "contabo-credentials", key = key } }
            }],
            [{ name = "DOMAIN_FILTER", value = join(",", local.external_dns_domains) }],
          )
          livenessProbe  = { httpGet = { path = "/healthz", port = "http-webhook" } }
          readinessProbe = { httpGet = { path = "/readyz", port = "http-webhook" } }
          securityContext = {
            runAsNonRoot             = true
            runAsUser                = 65532
            runAsGroup               = 65532
            readOnlyRootFilesystem   = true
            allowPrivilegeEscalation = false
            capabilities             = { drop = ["ALL"] }
            seccompProfile           = { type = "RuntimeDefault" }
          }
        }
      }
      domainFilters = local.external_dns_domains
      policy        = var.external_dns.policy
      registry      = "txt"
      # The owner id keeps clusters that share a zone from changing the
      # records of each other.
      txtOwnerId = var.cluster_name
      # Settings that the webhook needs (see its README): TXT names inside the
      # zone, no "*" inside a name, and longer timeouts for the rate limit of
      # the Contabo API.
      txtPrefix = "extdns-%%{record_type}."
      extraArgs = [
        "--txt-wildcard-replacement=wildcard",
        "--webhook-provider-read-timeout=30s",
        "--webhook-provider-write-timeout=60s",
      ]
      sources  = var.external_dns.sources
      interval = "1m"
    }),
    yamlencode(var.external_dns.helm_values),
  ]
}

locals {
  # Talos applies every document of an inline manifest, also Helm hooks, so
  # the module drops the hooks.
  cert_manager_manifest = var.cert_manager.enabled ? join("\n---\n", concat(
    [yamlencode({ apiVersion = "v1", kind = "Namespace", metadata = { name = "cert-manager" } })],
    [local.dns_credentials_secret["cert-manager"]],
    [for document in split("\n---\n", data.helm_template.cert_manager[0].manifest) : document if !strcontains(document, "helm.sh/hook")],
    [for document in split("\n---\n", data.helm_template.cert_manager_webhook[0].manifest) : document if !strcontains(document, "helm.sh/hook")],
    [for name, server in {
      letsencrypt-staging    = "https://acme-staging-v02.api.letsencrypt.org/directory"
      letsencrypt-production = "https://acme-v02.api.letsencrypt.org/directory"
      } : yamlencode({
        apiVersion = "cert-manager.io/v1"
        kind       = "ClusterIssuer"
        metadata   = { name = name }
        spec = {
          acme = {
            server              = server
            email               = var.cert_manager.acme_email
            privateKeySecretRef = { name = "${name}-account" }
            solvers = [{
              dns01 = {
                webhook = {
                  groupName  = "contabo.acme.codejourney.io"
                  solverName = "contabo"
                  config     = { secretName = "contabo-credentials" }
                }
              }
            }]
          }
        }
    })],
  )) : ""

  external_dns_manifest = var.external_dns.enabled ? join("\n---\n", concat(
    [yamlencode({ apiVersion = "v1", kind = "Namespace", metadata = { name = "external-dns" } })],
    [local.dns_credentials_secret["external-dns"]],
    [for document in split("\n---\n", data.helm_template.external_dns[0].manifest) : document if !strcontains(document, "helm.sh/hook")],
  )) : ""

  # The shared Gateway "public" in the namespace "gateway". Routes from every
  # namespace can use the Gateway. external-dns points the names of the routes
  # to the public addresses of the ingress nodes.
  shared_gateway_manifest = local.shared_gateway ? join("\n---\n", [
    yamlencode({ apiVersion = "v1", kind = "Namespace", metadata = { name = "gateway" } }),
    yamlencode({
      apiVersion = "cert-manager.io/v1"
      kind       = "Certificate"
      metadata   = { name = "wildcard", namespace = "gateway" }
      spec = {
        secretName = "wildcard-tls"
        dnsNames   = [var.gateway_api.domain, "*.${var.gateway_api.domain}"]
        issuerRef  = { kind = "ClusterIssuer", name = var.gateway_api.certificate_issuer }
      }
    }),
    yamlencode({
      apiVersion = "gateway.networking.k8s.io/v1"
      kind       = "Gateway"
      metadata = {
        name        = "public"
        namespace   = "gateway"
        annotations = { "external-dns.kubernetes.io/target" = join(",", local.ingress_public_ipv4) }
      }
      spec = {
        gatewayClassName = "cilium"
        listeners = flatten([
          for name, hostname in { apex = var.gateway_api.domain, wildcard = "*.${var.gateway_api.domain}" } : [
            {
              name          = "http-${name}"
              protocol      = "HTTP"
              port          = 80
              hostname      = hostname
              allowedRoutes = { namespaces = { from = "All" } }
            },
            {
              name          = "https-${name}"
              protocol      = "HTTPS"
              port          = 443
              hostname      = hostname
              tls           = { mode = "Terminate", certificateRefs = [{ kind = "Secret", name = "wildcard-tls" }] }
              allowedRoutes = { namespaces = { from = "All" } }
            },
          ]
        ])
      }
    }),
  ]) : ""

  ingress_manifests = concat(
    local.gateway_enabled ? [{ name = "gateway-api-crds", contents = data.http.gateway_api_crds[0].response_body }] : [],
    var.cert_manager.enabled ? [{ name = "cert-manager", contents = local.cert_manager_manifest }] : [],
    var.external_dns.enabled ? [{ name = "external-dns", contents = local.external_dns_manifest }] : [],
    local.shared_gateway ? [{ name = "gateway", contents = local.shared_gateway_manifest }] : [],
  )

  # Cilium settings for the Gateway API in host network mode: Envoy binds
  # ports 80 and 443 on the ingress nodes, because Contabo has no load
  # balancer.
  cilium_gateway_values = local.gateway_enabled ? yamlencode({
    gatewayAPI = {
      enabled     = true
      hostNetwork = { enabled = true, nodes = { matchLabels = { (local.ingress_label) = "true" } } }
      # "auto" asks the cluster, which helm_template cannot reach, so the class
      # would never be rendered.
      gatewayClass = { create = "true" }
    }
    envoy = {
      securityContext = {
        capabilities = {
          keepCapNetBindService = true
          envoy                 = ["NET_ADMIN", "SYS_ADMIN", "NET_BIND_SERVICE"]
        }
      }
    }
  }) : "{}"
}
