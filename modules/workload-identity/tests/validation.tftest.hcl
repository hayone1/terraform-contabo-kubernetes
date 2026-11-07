# Plan-only tests with mocked providers. They need no Contabo account, no
# cluster and no network. Run them with "terraform test" in the module folder.

mock_provider "contabo" {
  mock_data "contabo_object_storage" {
    defaults = {
      s3_url       = "https://eu2.contabostorage.com"
      s3_tenant_id = "tenant123"
      status       = "READY"
      cancel_date  = ""
    }
  }
  mock_data "contabo_object_storage_bucket" {
    defaults = {
      public_sharing = true
    }
  }
  mock_data "contabo_kubernetes_oidc_documents" {
    defaults = {
      # Same text as the mocked HTTP answers, so the checks pass.
      openid_configuration = "{}"
      jwks                 = "{}"
      key_ids              = ["kid1"]
    }
  }
  mock_resource "contabo_object_storage_bucket" {
    defaults = {
      public_sharing_link = "https://eu2.contabostorage.com/tenant123:wi-oidc"
    }
  }
}

mock_provider "helm" {
  mock_data "helm_template" {
    defaults = {
      manifest = "apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: webhook\n"
    }
  }
}

mock_provider "http" {
  mock_data "http" {
    defaults = {
      status_code   = 200
      response_body = "{}"
    }
  }
}

variables {
  cluster_name                    = "wi"
  service_account_public_keys_pem = ["-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n"]
  issuer = {
    object_storage = {
      object_storage_id = "11111111-2222-4333-8444-555555555555"
    }
  }
}

run "object_storage_issuer_address" {
  command = plan

  assert {
    condition     = !strcontains(output.talos_config_patch, "accepted") && !contains(keys(output.kube_apiserver_extra_args), "api-audiences")
    error_message = "Without a move, the patch must not change the accepted issuers or audiences."
  }

  assert {
    condition     = output.issuer_url == "https://eu2.contabostorage.com/tenant123:wi-oidc"
    error_message = "The issuer must be <s3 url>/<tenant>:<cluster>-oidc."
  }
  assert {
    condition     = output.jwks_uri == "https://eu2.contabostorage.com/tenant123:wi-oidc/openid/v1/jwks"
    error_message = "The key set address must be <issuer>/openid/v1/jwks."
  }
  assert {
    condition     = output.bucket_name == "wi-oidc"
    error_message = "The default bucket name must be <cluster>-oidc."
  }
  assert {
    condition     = contabo_object_storage_object.documents["jwks"].cache_control == "public, max-age=60"
    error_message = "Every document must carry a Cache-Control header."
  }
  assert {
    condition     = contabo_object_storage_object.documents["openid_configuration"].key == ".well-known/openid-configuration"
    error_message = "The discovery document key is wrong."
  }
}

run "talos_patch_documents" {
  command = plan

  variables {
    additional_accepted_issuers = ["https://old.example.com"]
    azure = {
      enabled   = true
      tenant_id = "9a31492d-f25a-451f-bb1b-3f258ce03363"
    }
  }

  assert {
    condition     = length(regexall("KubeServiceAccountConfig", output.talos_config_patch)) == 1
    error_message = "The patch must contain a KubeServiceAccountConfig document."
  }
  assert {
    condition     = strcontains(output.talos_config_patch, "https://old.example.com")
    error_message = "Older issuers must be listed as accepted issuers."
  }
  assert {
    condition     = length(regexall("KubeInlineManifestConfig", output.talos_config_patch)) == 1
    error_message = "The Azure webhook must be added as one inline manifest."
  }
  assert {
    condition     = jsonencode(output.kube_apiserver_extra_args["service-account-issuer"]) == jsonencode(["https://eu2.contabostorage.com/tenant123:wi-oidc", "https://old.example.com"])
    error_message = "With older issuers, the API server argument must list the main issuer first."
  }
  assert {
    condition     = jsonencode(yamldecode(split("\n---\n", output.talos_config_patch)[0]).accepted.audiences) == jsonencode(["https://eu2.contabostorage.com/tenant123:wi-oidc", "https://old.example.com"])
    error_message = "During a move, the API server must accept tokens with the old issuer as audience."
  }
  assert {
    condition     = jsonencode(output.kube_apiserver_extra_args["api-audiences"]) == jsonencode(["https://eu2.contabostorage.com/tenant123:wi-oidc", "https://old.example.com"])
    error_message = "During a move, api-audiences must list the new and the old issuer."
  }
  assert {
    condition     = output.azure.audience == "api://AzureADTokenExchange"
    error_message = "The Entra ID audience is wrong."
  }
}

run "external_issuer_publishes_nothing" {
  command = plan

  variables {
    issuer = {
      mode         = "external"
      external_url = "https://oidc.example.com/cluster"
    }
  }

  assert {
    condition     = output.issuer_url == "https://oidc.example.com/cluster"
    error_message = "The external issuer must be used as it is."
  }
  assert {
    condition     = length(contabo_object_storage_object.documents) == 0 && length(contabo_object_storage_bucket.this) == 0
    error_message = "The external mode must not create a bucket or objects."
  }
}

run "existing_bucket" {
  command = plan

  variables {
    issuer = {
      object_storage = {
        object_storage_id = "11111111-2222-4333-8444-555555555555"
        bucket_name       = "shared-oidc"
        create_bucket     = false
      }
    }
  }

  assert {
    condition     = length(contabo_object_storage_bucket.this) == 0
    error_message = "With create_bucket = false the module must not create a bucket."
  }
  assert {
    condition     = output.issuer_url == "https://eu2.contabostorage.com/tenant123:shared-oidc"
    error_message = "The issuer must use the existing bucket name."
  }
}

run "reject_private_existing_bucket" {
  command = plan

  variables {
    issuer = {
      object_storage = {
        object_storage_id = "11111111-2222-4333-8444-555555555555"
        bucket_name       = "private-bucket"
        create_bucket     = false
      }
    }
  }

  override_data {
    target = data.contabo_object_storage_bucket.existing[0]
    values = { public_sharing = false }
  }

  expect_failures = [data.contabo_object_storage_bucket.existing]
}

run "reject_cancelled_object_storage" {
  command = plan

  override_data {
    target = data.contabo_object_storage.this[0]
    values = {
      s3_url       = "https://eu2.contabostorage.com"
      s3_tenant_id = "tenant123"
      status       = "READY"
      cancel_date  = "2026-12-31"
    }
  }

  expect_failures = [data.contabo_object_storage.this]
}

run "reject_http_external_issuer" {
  command = plan
  variables {
    issuer = {
      mode         = "external"
      external_url = "http://oidc.example.com"
    }
  }
  expect_failures = [var.issuer]
}

run "reject_trailing_slash" {
  command = plan
  variables {
    issuer = {
      mode         = "external"
      external_url = "https://oidc.example.com/"
    }
  }
  expect_failures = [var.issuer]
}

run "reject_bad_bucket_name" {
  command = plan
  variables {
    issuer = {
      object_storage = {
        object_storage_id = "x"
        bucket_name       = "Bad_Name"
      }
    }
  }
  expect_failures = [var.issuer]
}

run "reject_long_cache_time" {
  command = plan
  variables {
    issuer = {
      object_storage = {
        object_storage_id     = "x"
        cache_max_age_seconds = 86400
      }
    }
  }
  expect_failures = [var.issuer]
}

run "reject_azure_without_tenant" {
  command = plan
  variables {
    azure = { enabled = true }
  }
  expect_failures = [var.azure]
}

run "reject_bad_cluster_name" {
  command = plan
  variables {
    cluster_name = "My Cluster"
  }
  expect_failures = [var.cluster_name]
}

run "outputs_for_external_publishing_and_manifest_sync" {
  command = plan

  variables {
    azure = {
      enabled   = true
      tenant_id = "9a31492d-f25a-451f-bb1b-3f258ce03363"
    }
    service_account_public_keys_pem = [
      "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n",
      "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n",
    ]
  }

  assert {
    condition     = jsonencode(keys(output.documents)) == jsonencode([".well-known/openid-configuration", "openid/v1/jwks"])
    error_message = "The documents output must map both object keys to their content."
  }
  assert {
    condition     = can(regex("^[0-9a-f]{64}$", output.inline_manifests_sha256))
    error_message = "With Azure enabled, the manifest checksum must be a SHA-256 value."
  }
  assert {
    condition     = length(data.contabo_kubernetes_oidc_documents.this.public_keys_pem) == 1
    error_message = "Duplicate keys must be removed before the key set is computed."
  }
}

run "no_manifest_checksum_without_cloud" {
  command = plan

  assert {
    condition     = output.inline_manifests_sha256 == null && length(output.inline_manifests) == 0
    error_message = "Without a cloud integration there are no manifests and no checksum."
  }
}

run "reject_fractional_generation" {
  command = plan
  variables {
    issuer_generation = 1.5
  }
  expect_failures = [var.issuer_generation]
}

run "reject_key_that_is_not_pem" {
  command = plan
  variables {
    service_account_public_keys_pem = ["LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0K"]
  }
  expect_failures = [var.service_account_public_keys_pem]
}

run "reject_bad_older_issuer" {
  command = plan
  variables {
    additional_accepted_issuers = ["http://old.example.com/"]
  }
  expect_failures = [var.additional_accepted_issuers]
}

run "reject_failed_object_storage" {
  command = plan

  override_data {
    target = data.contabo_object_storage.this[0]
    values = {
      s3_url       = "https://eu2.contabostorage.com"
      s3_tenant_id = "tenant123"
      status       = "ERROR"
      cancel_date  = ""
    }
  }

  expect_failures = [data.contabo_object_storage.this]
}

# The next three runs share one state. The first run stores the issuer, the
# second run changes the bucket and must be stopped by the issuer guard, and
# the third run raises issuer_generation, which accepts the new issuer.
run "guard_first_apply" {
  command = apply

  assert {
    condition     = terraform_data.issuer.output == "https://eu2.contabostorage.com/tenant123:wi-oidc"
    error_message = "The guard must store the first issuer."
  }
}

run "guard_blocks_issuer_change" {
  command = plan

  variables {
    issuer = {
      object_storage = {
        object_storage_id = "11111111-2222-4333-8444-555555555555"
        bucket_name       = "wi-oidc-new"
      }
    }
  }

  expect_failures = [
    contabo_object_storage_bucket.this,
    output.issuer_url,
    output.kube_apiserver_extra_args,
    output.talos_config_patch,
  ]
}

run "guard_blocks_create_bucket_switch" {
  command = plan

  # The same bucket, but the module would no longer own it. Terraform would
  # delete the bucket, so the location guard stops the plan.
  variables {
    issuer = {
      object_storage = {
        object_storage_id = "11111111-2222-4333-8444-555555555555"
        bucket_name       = "wi-oidc"
        create_bucket     = false
      }
    }
  }

  expect_failures = [
    contabo_object_storage_object.documents,
    output.issuer_url,
    output.kube_apiserver_extra_args,
    output.talos_config_patch,
  ]
}

run "guard_needs_state_rm_for_a_move" {
  command = plan

  # A new issuer_generation accepts the new issuer, but the old documents are
  # still in the state. Terraform would delete them, so the location guard
  # stops the plan until the user removes them from the state.
  variables {
    issuer_generation = 2
    issuer = {
      mode         = "external"
      external_url = "https://oidc.example.com/wi"
    }
  }

  expect_failures = [
    output.issuer_url,
    output.kube_apiserver_extra_args,
    output.talos_config_patch,
  ]
}

# A separate state stands for the state after "terraform state rm". The new
# generation and the new location are accepted.
run "move_after_state_rm" {
  command   = apply
  state_key = "after_state_rm"

  variables {
    issuer_generation           = 2
    additional_accepted_issuers = ["https://eu2.contabostorage.com/tenant123:wi-oidc"]
    issuer = {
      mode         = "external"
      external_url = "https://oidc.example.com/wi"
    }
  }

  assert {
    condition     = output.issuer_url == "https://oidc.example.com/wi" && terraform_data.documents_location.output == "external"
    error_message = "After the state rm, the move must be accepted."
  }
}
