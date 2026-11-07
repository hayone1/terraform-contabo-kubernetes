locals {
  use_object_storage = var.issuer.mode == "object_storage"
  storage            = local.use_object_storage ? var.issuer.object_storage : null

  bucket_name   = local.use_object_storage ? coalesce(local.storage.bucket_name, "${var.cluster_name}-oidc") : null
  create_bucket = local.use_object_storage && try(local.storage.create_bucket, true)

  # Contabo serves a public bucket at <s3 url>/<s3 tenant id>:<bucket>. The
  # address only depends on values that exist before the bucket, so it is
  # known at plan time and can go into the first machine configuration.
  object_storage_issuer = local.use_object_storage ? "${trimsuffix(data.contabo_object_storage.this[0].s3_url, "/")}/${data.contabo_object_storage.this[0].s3_tenant_id}:${local.bucket_name}" : null

  issuer_url = local.use_object_storage ? local.object_storage_issuer : var.issuer.external_url
  jwks_uri   = "${local.issuer_url}/openid/v1/jwks"

  # Contabo puts a cache in front of public buckets. An object without a
  # Cache-Control header can stay in that cache for a long time, and nobody can
  # empty the cache. A short max-age keeps key rotations visible quickly.
  cache_control = local.use_object_storage ? "public, max-age=${local.storage.cache_max_age_seconds}" : null

  accepted_issuers = distinct(concat([local.issuer_url], var.additional_accepted_issuers))
  old_issuers      = [for issuer in local.accepted_issuers : issuer if issuer != local.issuer_url]
  migrating        = length(local.old_issuers) > 0

  # A plain string works with every Talos version. A list (several issuers)
  # needs a Talos version that accepts repeated extra arguments (1.14 does).
  # jsondecode lets the two branches have different types.
  kube_apiserver_extra_args = merge(
    {
      "service-account-issuer"   = jsondecode(local.migrating ? jsonencode(local.accepted_issuers) : jsonencode(local.issuer_url))
      "service-account-jwks-uri" = local.jwks_uri
    },
    # Tokens from before a move carry the old issuer as their audience.
    local.migrating ? { "api-audiences" = local.accepted_issuers } : {},
  )
}

data "contabo_object_storage" "this" {
  count = local.use_object_storage ? 1 : 0
  id    = local.storage.object_storage_id

  lifecycle {
    postcondition {
      condition     = contains(["READY", "UPGRADING"], self.status)
      error_message = "The object storage ${local.storage.object_storage_id} has the status ${self.status}. Only an object storage with the status READY or UPGRADING serves the issuer documents."
    }
    postcondition {
      condition     = self.cancel_date == ""
      error_message = "The object storage ${local.storage.object_storage_id} is cancelled for ${self.cancel_date}. The issuer would stop working on that date, and every cloud login of the cluster would fail."
    }
  }
}

# Guards the issuer address. ignore_changes keeps the first address in the
# state, and the checks below compare it with the current address. A new
# issuer_generation replaces this resource, which accepts the new address.
resource "terraform_data" "issuer" {
  input            = local.issuer_url
  triggers_replace = var.issuer_generation

  lifecycle {
    ignore_changes = [input]
  }
}

# Remembers where the documents of the issuer live. issuer_generation does not
# replace this resource. A changed bucket or object storage would make
# Terraform delete the old documents, and Entra ID needs the old documents for
# the tokens that pods already have. The move therefore needs
# "terraform state rm" of the old documents, the old bucket and this resource,
# so that the old documents stay online.
resource "terraform_data" "documents_location" {
  input = local.documents_location

  lifecycle {
    ignore_changes = [input]
  }
}

locals {
  # A bucket that the module did not create gets a suffix, so that a switch of
  # create_bucket is stopped too: the switch would delete the module's bucket.
  documents_location = (
    !local.use_object_storage ? "external" :
    "${local.storage.object_storage_id}/${local.bucket_name}${local.create_bucket ? "" : " (existing bucket)"}"
  )

  issuer_unchanged = terraform_data.issuer.output == local.issuer_url
  issuer_changed_message = join(" ", [
    "The service account issuer would change from \"${terraform_data.issuer.output}\" to \"${local.issuer_url}\".",
    "A new issuer makes every cloud trust (for example Entra ID federated credentials) and every token that pods already have invalid.",
    "If you really want a new issuer, follow \"Change the issuer\" in the module README: raise issuer_generation by one, list the old issuer in additional_accepted_issuers for one day, and remove the old documents from the Terraform state first.",
  ])

  location_unchanged = terraform_data.documents_location.output == local.documents_location
  location_changed_message = terraform_data.documents_location.output == "external" ? join(" ", [
    "The issuer documents would move from your own server (issuer mode \"external\") to \"${local.documents_location}\".",
    "The module managed no documents before, so nothing is deleted. Confirm the move:",
    "run \"terraform state rm ${local.module_address}terraform_data.documents_location\", and plan again.",
    ]) : join(" ", [
    "The issuer documents would move from \"${terraform_data.documents_location.output}\" to \"${local.documents_location}\".",
    "Terraform would delete the old documents, and Entra ID would then refuse every token that pods already have.",
    "Tell Terraform to forget the old documents first, so that they stay online: run \"terraform state rm\" for",
    "${local.module_address}contabo_object_storage_object.documents, ${local.module_address}contabo_object_storage_bucket.this (if the module created the bucket)",
    "and ${local.module_address}terraform_data.documents_location. The README section \"Change the issuer\" lists every step.",
  ])

  # Terraform has no function for the address of a module, so the message
  # uses a placeholder that the reader replaces.
  module_address = "module.<name of this module>."
}

data "contabo_kubernetes_oidc_documents" "this" {
  issuer          = local.issuer_url
  jwks_uri        = local.jwks_uri
  public_keys_pem = distinct(var.service_account_public_keys_pem)
}

resource "contabo_object_storage_bucket" "this" {
  count             = local.create_bucket ? 1 : 0
  name              = local.bucket_name
  object_storage_id = local.storage.object_storage_id
  public_sharing    = true

  lifecycle {
    # Stop before Terraform replaces the bucket of a running cluster.
    precondition {
      condition     = local.issuer_unchanged
      error_message = local.issuer_changed_message
    }
    precondition {
      condition     = local.location_unchanged
      error_message = local.location_changed_message
    }
    postcondition {
      condition     = self.public_sharing_link == local.object_storage_issuer
      error_message = "Contabo reports the public address \"${self.public_sharing_link}\" for the bucket, but the module expected \"${local.object_storage_issuer}\". The issuer would be wrong. Please report this as a bug."
    }
  }
}

data "contabo_object_storage_bucket" "existing" {
  count             = local.use_object_storage && !local.create_bucket ? 1 : 0
  name              = local.bucket_name
  object_storage_id = local.storage.object_storage_id

  lifecycle {
    postcondition {
      condition     = self.public_sharing
      error_message = "The bucket ${local.bucket_name} is not shared publicly. Entra ID and other cloud providers cannot read the issuer documents from a private bucket. Turn on public sharing for the bucket, or let the module create its own bucket."
    }
  }
}

locals {
  documents = {
    openid_configuration = {
      key     = ".well-known/openid-configuration"
      content = data.contabo_kubernetes_oidc_documents.this.openid_configuration
    }
    jwks = {
      key     = "openid/v1/jwks"
      content = data.contabo_kubernetes_oidc_documents.this.jwks
    }
  }
}

resource "contabo_object_storage_object" "documents" {
  for_each = local.use_object_storage ? local.documents : {}

  object_storage_id = local.storage.object_storage_id
  bucket            = local.create_bucket ? contabo_object_storage_bucket.this[0].name : data.contabo_object_storage_bucket.existing[0].name
  key               = each.value.key
  content           = each.value.content
  content_type      = "application/json"
  cache_control     = local.cache_control

  lifecycle {
    precondition {
      condition     = local.issuer_unchanged
      error_message = local.issuer_changed_message
    }
    precondition {
      condition     = local.location_unchanged
      error_message = local.location_changed_message
    }
  }
}
