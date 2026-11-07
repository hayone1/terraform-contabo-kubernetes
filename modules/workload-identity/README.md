# Workload identity module

This module lets pods in a Talos Kubernetes cluster on Contabo log in to cloud services without a stored password or key. The first supported cloud is Microsoft Entra ID (Azure). The module publishes the public part of the cluster's signing key in a public Contabo bucket, and Entra ID trusts the tokens that the cluster signs with that key.

The main module of this repository will call this module. You can also call this module from your own Talos configuration.

## How workload identity works

Kubernetes gives every pod a token. A token is a signed text that says which service account the pod runs as. Workload identity uses these tokens instead of passwords. The process has five steps:

1. The Kubernetes API server signs every token with the cluster's service account key. The API server also writes an issuer into every token. The issuer is a web address that names the cluster, for example `https://eu2.contabostorage.com/73c52bffc2604fccac2b286674b4bd45:wi-live-oidc`.
2. Two documents must be readable at the issuer address. The discovery document (`/.well-known/openid-configuration`) says where the keys are. The JSON Web Key Set, or JWKS (`/openid/v1/jwks`), contains the public part of the service account key.
3. In Entra ID, you create a federated credential. The federated credential says: "Trust tokens from this issuer for this service account."
4. The Azure workload identity webhook adds a short-lived token file to every pod that asks for workload identity.
5. The application in the pod sends the token to Entra ID and gets an Entra ID access token back. Entra ID checks the token signature with the JWKS from step 2.

This module handles steps 1, 2 and 4. You create the Entra ID objects of step 3 yourself, for example with the `azuread` Terraform provider. The module never changes anything in Entra ID.

## Why the module uses a Contabo bucket

The issuer documents must be on a public HTTPS address that stays the same for the whole life of the cluster. A public bucket in your Contabo object storage is such an address, and you already pay for the object storage. The bucket does not depend on the health of the cluster, so cloud logins keep working while you repair the cluster.

The same issuer also works for other clouds that support OpenID Connect federation, such as AWS and Google Cloud. Only step 4 is specific to Azure.

## What you need

- The provider `hayone1/contabo` in version 0.3.1 or newer. The module uses its `contabo_object_storage_object` resource and its `contabo_kubernetes_oidc_documents` data source. Version 0.3.1 fixes a bug that made the bucket private during an update.
- Talos 1.14 or newer for the `talos_config_patch` output. Older Kubernetes setups can use the `kube_apiserver_extra_args` output instead.
- Terraform 1.9 or newer. OpenTofu works only after `hayone1/contabo` is listed in the OpenTofu Registry. Until then, OpenTofu cannot download the provider. A test with OpenTofu 1.13.9 on 2026-11-06 confirmed this limit.
- A Contabo object storage. The module creates its own bucket in the object storage. A bucket costs nothing extra.
- For Azure: the ID of your Entra ID tenant.

The module computes the issuer documents from the service account key. The module does not need to reach the cluster, so a plan works even when the cluster is down or only reachable through Tailscale.

## Example

```hcl
resource "talos_machine_secrets" "this" {}

module "workload_identity" {
  source = "./modules/workload-identity"

  cluster_name = "prod"

  issuer = {
    object_storage = {
      object_storage_id = "00000000-0000-4000-8000-000000000000"
    }
  }

  # Talos stores the service account key base64-encoded.
  service_account_public_keys_pem = [
    base64decode(talos_machine_secrets.this.machine_secrets.certs.k8s_serviceaccount.key),
  ]

  azure = {
    enabled   = true
    tenant_id = "9a31492d-f25a-451f-bb1b-3f258ce03363"
  }
}

data "talos_machine_configuration" "control_plane" {
  # ... cluster name, endpoint, secrets ...
  config_patches = [module.workload_identity.talos_config_patch]
}
```

The module creates the bucket `prod-oidc`. The issuer address is `<object storage S3 URL>/<S3 tenant ID>:prod-oidc`. Terraform knows the issuer address during the plan, because the address only depends on the object storage and the bucket name.

## Connect a workload to Entra ID

1. Create an Entra ID app registration and a service principal for the workload.
2. Create a federated credential on the app registration. Use the issuer from the `issuer_url` output. Use the subject `system:serviceaccount:<namespace>:<service account>`, and the audience `api://AzureADTokenExchange`.

   ```hcl
   resource "azuread_application_federated_identity_credential" "app" {
     application_id = azuread_application.app.id
     display_name   = "prod-billing-api"
     issuer         = module.workload_identity.issuer_url
     subject        = "system:serviceaccount:billing:api"
     audiences      = ["api://AzureADTokenExchange"]
   }
   ```

3. Give the Kubernetes service account the annotation `azure.workload.identity/client-id` with the client ID of the app registration.
4. Give the pod the label `azure.workload.identity/use: "true"`.
5. Make the application read the token from the file that the variable `AZURE_FEDERATED_TOKEN_FILE` names. The Azure SDKs do this when you use `DefaultAzureCredential` or `WorkloadIdentityCredential`.

The webhook adds the variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_AUTHORITY_HOST` and `AZURE_FEDERATED_TOKEN_FILE` to the pod. The token file path is different for every pod, so the application must read the variable and must not use a fixed path.

## Inputs

| Name | What the input does | Default |
|---|---|---|
| `cluster_name` | The name of the cluster. The default bucket name is `<cluster_name>-oidc`. | none |
| `issuer.mode` | `object_storage` publishes the documents in a Contabo bucket. `external` only computes the documents, and you publish them at `issuer.external_url`. The `external` mode still needs a configured `hayone1/contabo` provider with Contabo API credentials, because the provider computes the documents and checks its credentials when it starts. | `object_storage` |
| `issuer.object_storage.object_storage_id` | The object storage that holds the bucket. | none |
| `issuer.object_storage.bucket_name` | The bucket name. | `<cluster_name>-oidc` |
| `issuer.object_storage.create_bucket` | Whether the module creates the bucket. With `false`, the bucket must exist and must be shared publicly. | `true` |
| `issuer.object_storage.cache_max_age_seconds` | How long the Contabo cache may keep a document, from 0 to 3600 seconds. | `60` |
| `issuer.external_url` | The issuer address for the `external` mode. | none |
| `service_account_public_keys_pem` | The service account keys of the cluster in PEM format. | none |
| `additional_accepted_issuers` | Older issuers that the API server must still accept. See "Change the issuer". | `[]` |
| `issuer_generation` | A number that protects the issuer from accidental changes. See "Change the issuer". | `1` |
| `kubernetes_api` | Optional access to the API server for a comparison check. | `null` |
| `azure` | The Azure settings: `enabled`, `tenant_id`, `webhook_chart_version`, `webhook_namespace`, `webhook_helm_values` and `kubernetes_version`. | disabled |

## Outputs

| Name | What the output contains |
|---|---|
| `issuer_url` | The issuer address. Use this value in every federated credential. |
| `jwks_uri` | The address of the JWKS. |
| `talos_config_patch` | A Talos 1.14 patch for control plane nodes. The patch sets the issuer and the JWKS address, and it adds the webhook as an inline manifest. |
| `kube_apiserver_extra_args` | The API server arguments for other Kubernetes setups. |
| `inline_manifests` | The webhook manifests as a list of objects with a name and the manifest text. |
| `inline_manifests_sha256` | A checksum of the inline manifests, or null without a cloud integration. Use the checksum to trigger the manifest sync. See "Talos does not update the webhook by itself". |
| `openid_configuration`, `jwks`, `key_ids` | The published documents and the key IDs. |
| `documents` | A map from the object key to the document content. Use this map to publish the documents yourself in the `external` mode. |
| `bucket_name` | The bucket that holds the documents. |
| `azure` | The tenant ID, the issuer, the audience and the subject format for Entra ID. |

## Change the issuer

The issuer must not change after the cluster is running. A new issuer makes every token that pods already have invalid. A new issuer also breaks every federated credential that names the old issuer. For this reason, the module stops the plan with an error when the issuer address changes.

Follow these steps when you need a new issuer on purpose, for example when you move the bucket to another object storage:

1. Add a federated credential for the new issuer in Entra ID next to every old federated credential. Entra ID allows 20 federated credentials per app registration, so one more credential is fine. Cloud logins with new tokens then work as soon as the new documents are online.
2. Tell Terraform to forget the old bucket and the old documents, so that Terraform does not delete them. Entra ID still needs the old documents for the tokens that pods already have.

   ```sh
   terraform state rm 'module.workload_identity.contabo_object_storage_bucket.this[0]'
   terraform state rm 'module.workload_identity.contabo_object_storage_object.documents'
   terraform state rm 'module.workload_identity.terraform_data.documents_location'
   ```

   Skip the first command when the module did not create the old bucket (`create_bucket = false`). The last command removes the guard that remembers where the documents live. Without these commands, the module stops the plan, because Terraform would delete the old documents.
3. Set the new bucket or the new object storage.
4. Raise `issuer_generation` by one, for example from `1` to `2`.
5. Add the old issuer to `additional_accepted_issuers`. The module then tells the API server to accept the old issuer and the old token audience. Every token that a pod already has carries the old issuer as its audience, so the API server would refuse these tokens without the old audience. A live test on 2026-11-06 showed both cases: a token with only the old audience got HTTP 200 during the move and HTTP 401 after the move.
6. Apply the change. Talos restarts kube-apiserver with the new settings.
7. Wait one day. Kubernetes replaces every pod token within that time.
8. Remove the old issuer from `additional_accepted_issuers`, and apply again.
9. Delete the old federated credentials in Entra ID, and delete the old bucket in the Contabo control panel.

## Add the module to a running cluster

A Talos cluster without this module already has an issuer. Talos uses the address of the control plane, for example `https://203.0.113.10:6443`, as the issuer. Adding the module to a running cluster is therefore a move to a new issuer.

List the old address in `additional_accepted_issuers` for one day:

```hcl
additional_accepted_issuers = ["https://203.0.113.10:6443"]
```

Without this setting, every pod keeps a token that the API server refuses until kubelet renews the token. Kubelet renews tokens about once an hour, but some programs read the token file only when they start, and those programs fail until they restart. The command `kubectl get --raw /.well-known/openid-configuration | jq -r .issuer` shows the current issuer of a cluster.

## Rotate the service account key

The JWKS contains the public part of every key in `service_account_public_keys_pem`. During a key rotation, list the new key first and the old key second. Entra ID can keep a copy of the JWKS for a while, so keep the old key in the list for at least one day. Then remove the old key.

The module only publishes the keys. The API server itself must also accept tokens that the old key signed. In Talos, add the old public key to `accepted.publicKeys` of the `KubeServiceAccountConfig` document for the same day:

```yaml
apiVersion: v1alpha1
kind: KubeServiceAccountConfig
accepted:
  publicKeys:
    - |
      -----BEGIN PUBLIC KEY-----
      MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...
      -----END PUBLIC KEY-----
```

A rebuild of the cluster with the same Talos machine secrets is not a key rotation. The key stays the same, so nothing changes for Entra ID.

## What the checks mean

The module has three `check` blocks. A failed check prints a warning. A failed check never stops a plan or an apply.

- `published_discovery_document` and `published_jwks` read the documents through the public address, the same way Entra ID reads them. A warning right after the first apply is normal, because the bucket did not exist during the plan.
- `api_server_jwks` compares the JWKS that the API server serves with the published JWKS. The check only runs when you set `kubernetes_api`. A warning means that the API server signs tokens with a key that the module does not know.

## Edge cases that the module handles

- The issuer address is known during the plan. The first Talos configuration can contain the issuer before the bucket exists.
- The module checks that the object storage has the status `READY` or `UPGRADING` and has no cancellation date. A cancelled object storage would stop every cloud login of the cluster.
- The module checks that every service account key is in PEM format. Talos stores the key base64-encoded, and a forgotten `base64decode()` would otherwise publish an empty key set.
- The module removes duplicate keys from `service_account_public_keys_pem` before the module computes the key set.
- With `create_bucket = false`, the module checks that the bucket exists and is shared publicly.
- The module checks after the bucket creation that Contabo reports the expected public address.
- The module stops the plan when the issuer would change, unless you raise `issuer_generation`.
- A second guard stops the plan when the documents would move to another bucket or object storage while the old documents are still in the Terraform state. Terraform would otherwise delete the old documents, and Entra ID would refuse the tokens that pods already have. The error message lists the `terraform state rm` commands.
- A switch from `create_bucket = true` to `create_bucket = false` would delete the bucket of the module. The second guard stops this switch too. Remove the bucket and the guard from the state first with `terraform state rm 'module.workload_identity.contabo_object_storage_bucket.this[0]'` and `terraform state rm 'module.workload_identity.terraform_data.documents_location'`, so that the bucket and the documents stay online.
- A move from the `external` mode to a bucket deletes nothing. The guard still asks you to confirm the move with `terraform state rm` of the guard alone.
- A rebuild of the cluster with the same Talos machine secrets keeps the same service account key. The issuer documents and every federated credential then stay valid. A live test on 2026-11-06 reset the test node, built the cluster again with another Kubernetes version, and Entra ID logins kept working without any change.
- Every document gets `Content-Type: application/json` and a `Cache-Control` header.
- When someone changes or deletes a document outside of Terraform, the next plan shows the change, and the next apply repairs the document.
- The documents are computed from the service account key, so the module works with every admin access mode, including Tailscale.

## Known problems that the module cannot fix

### The Contabo cache can serve an old document

Contabo serves public buckets through a cache. The cache respects the `Cache-Control` header of an object, so the module's documents are never older than `cache_max_age_seconds`. An object that someone uploads without a `Cache-Control` header is different. The cache can keep such an object for about 30 minutes after a change. Two tests on 2026-11-05 measured between 25 and 30 minutes, and customers cannot empty the cache.

Never upload files into the issuer bucket by hand. If somebody did, Terraform repairs the object at once, but Entra ID can see the old copy until the cache expires. While Entra ID sees a wrong JWKS, every login fails with an error like this one:

```
AADSTS7000272: The certificate with identifier L7qelbsWUTZCU_Gw6MHLozO30bbQ3OT1ll9c2LcxM60 used to sign the federated credential could not be found in the metadata of identity provider https://eu2.contabostorage.com/...
```

The live test produced exactly this error after a hand-made upload. The logins worked again as soon as the cache expired, about 30 minutes later. Ask Contabo support to clear the cache if you cannot wait.

### Every object in the bucket is public

Public sharing makes every object in the bucket readable by anybody. Contabo does not allow anybody to list the bucket, but a person who knows a name can read the object. Use the bucket only for the issuer documents. Never put backups or other files into the bucket.

### A missing document returns HTTP 403

Contabo answers HTTP 403 (forbidden) instead of HTTP 404 (not found) for a missing object in a public bucket. A 403 in a check warning usually means that the document does not exist yet.

### The issuer depends on the object storage

The cluster's cloud logins work only while the object storage exists. If the object storage is cancelled or the bucket is deleted, Entra ID cannot check new tokens, and every cloud login of the cluster fails. Contabo allows one object storage per region, so other projects often share the object storage. Do not cancel the object storage while a cluster uses the bucket.

### The webhook blocks labelled pods while the webhook is down

The Azure webhook uses the failure policy `Fail`. While the webhook is down, Kubernetes cannot create pods with the label `azure.workload.identity/use: "true"`. Other pods are not affected.

### Talos does not update the webhook by itself

Talos creates the inline manifests when the cluster starts. Talos stores a changed manifest after a configuration change, but Talos does not apply the changed manifest to the cluster. A live test on Talos 1.14.5 confirmed this behavior.

After you change `webhook_chart_version` or `webhook_helm_values`, apply the Terraform change, and then run this command with the current Kubernetes version:

```sh
talosctl -n <control plane IP> upgrade-k8s --to 1.37.1
```

The command keeps the Kubernetes version and applies the stored manifests. The main module of this repository will run this step for you.

Until then, let Terraform run the command whenever the manifests change. The `inline_manifests_sha256` output changes with every change of the manifests, so the step below runs only when it is needed. The live test in `tests/live/workload-identity` uses the same step.

```hcl
resource "terraform_data" "sync_manifests" {
  triggers_replace = module.workload_identity.inline_manifests_sha256

  provisioner "local-exec" {
    command = <<-EOT
      talosctl --talosconfig ./talosconfig -n 203.0.113.10 -e 203.0.113.10 health --wait-timeout 15m
      talosctl --talosconfig ./talosconfig -n 203.0.113.10 -e 203.0.113.10 upgrade-k8s --to 1.36.6
    EOT
  }

  depends_on = [talos_machine_configuration_apply.control_plane]
}
```

The `health` command waits until the cluster works. Without the wait, the first run after a new cluster fails, because the API server is not ready yet.

Talos never deletes objects of a manifest that you remove. When you turn off `azure.enabled`, delete the namespace `azure-workload-identity-system` and the webhook configuration `azure-wi-webhook-mutating-webhook-configuration` yourself.

## Upgrade the module

Apply an upgrade of the module on its own, without other changes. Versions before 2026-11-06 had no guard for the location of the documents. The first apply after the upgrade creates the guard with the current location. A move of the documents in the same apply would not be stopped, and Terraform would delete the old documents.

## Production checklist

Check these points before a cluster with this module goes into production:

1. Keep the Terraform state in a protected remote backend. When you pass the Talos service account key as in the example, the state of the module holds the private key, because Terraform stores the inputs of the data source that computes the documents. Somebody with the private key can create tokens for every service account of the cluster. If the module runs in a separate configuration, pass only the public key, for example from the `public_key_pem` attribute of a `tls_public_key` data source in the configuration that owns the Talos secrets.
2. Never delete the Talos machine secrets. A new service account key means new key IDs, and Entra ID then refuses every token of the cluster until the new key set is published. The module publishes the new key set automatically, but pods with old tokens fail until Kubernetes renews their tokens.
3. Never upload files into the issuer bucket by hand. See "The Contabo cache can serve an old document".
4. Do not cancel the object storage, and do not delete the bucket while the cluster runs. See "The issuer depends on the object storage".
5. Keep `issuer_generation` at its value. Change the issuer only with the steps in "Change the issuer".
6. Run the manifest sync after every change of the webhook settings. See "Talos does not update the webhook by itself".
7. Watch the warnings of the three checks in your plans. A warning about the published documents means that cloud logins of the cluster may fail.
8. Give every workload its own Kubernetes service account and its own federated credential. A federated credential trusts exactly one service account in one namespace, and that limit keeps a broken workload from using the cloud access of another workload.

## Remove the module

`terraform destroy` deletes the documents and the bucket. After that, Entra ID cannot check the tokens of the cluster, and every cloud login of the cluster fails at once. Delete the federated credentials of the cluster in Entra ID too, because a federated credential without a working issuer is useless.

## Examples

- `examples/headlamp-entra-login` installs Headlamp with an Entra ID login. oauth2-proxy logs in to Entra ID with workload identity and needs no client secret.
- `examples/rancher-entra-login` installs Rancher with an Entra ID login. Rancher needs a client secret, so a job in the cluster creates short-lived secrets with workload identity and hands them to Rancher.

## Tests

- `terraform test` in this folder runs plan-only tests with mocked providers. The tests need Terraform 1.11 or newer, because one test uses a separate state (`state_key`). The module itself works with Terraform 1.9. The tests need no account and no network.
- `tests/live/workload-identity` in the repository runs a live test on Contabo and Entra ID. The live test builds a one-node Talos cluster, publishes the documents, and exchanges a pod token at Entra ID. See the README in that folder.
