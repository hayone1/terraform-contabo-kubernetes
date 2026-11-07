# Backups to a bucket in a Contabo object storage. talos-backup saves
# encrypted etcd snapshots, and Longhorn backs up its volumes. The bucket must
# already exist: the module never creates or deletes it, so a destroyed
# cluster keeps its backups.

locals {
  etcd_backup     = var.backups.etcd.enabled
  longhorn_backup = var.backups.longhorn.enabled
  backups_enabled = local.etcd_backup || local.longhorn_backup

  # nonsensitive() only reveals whether credentials were given, not the
  # credentials themselves. count cannot use sensitive values.
  backup_reads_credentials = local.backups_enabled && nonsensitive(var.backup_s3_credentials == null)

  backup_s3_url = local.backups_enabled ? trimsuffix(data.contabo_object_storage.backups[0].s3_url, "/") : ""

  # Contabo names the S3 region in the first label of the S3 address, for
  # example "eu2" in https://eu2.contabostorage.com.
  backup_s3_region = local.backups_enabled ? coalesce(var.backups.s3_region, try(regex("^https?://([a-z0-9-]+)\\.", local.backup_s3_url)[0], "default")) : ""

  # The data source stops the plan when the bucket does not exist.
  backup_bucket = local.backups_enabled ? data.contabo_object_storage_bucket.backups[0].name : ""

  backup_credentials = local.backups_enabled ? (
    local.backup_reads_credentials
    ? { access_key = data.contabo_object_storage_credentials.backups[0].access_key, secret_key = data.contabo_object_storage_credentials.backups[0].secret_key }
    : var.backup_s3_credentials
  ) : null
}

data "contabo_object_storage" "backups" {
  count = local.backups_enabled ? 1 : 0
  id    = var.backups.object_storage_id

  lifecycle {
    postcondition {
      condition     = contains(["READY", "UPGRADING"], self.status)
      error_message = "The object storage ${coalesce(var.backups.object_storage_id, "-")} has the status ${self.status}. Backups need an object storage with the status READY or UPGRADING."
    }
  }
}

data "contabo_object_storage_credentials" "backups" {
  count             = local.backup_reads_credentials ? 1 : 0
  object_storage_id = var.backups.object_storage_id

  lifecycle {
    postcondition {
      condition     = self.access_key != ""
      error_message = "The Contabo API user has no S3 credentials for the object storage ${coalesce(var.backups.object_storage_id, "-")}. Set backup_s3_credentials."
    }
  }
}

data "contabo_object_storage_bucket" "backups" {
  count             = local.backups_enabled ? 1 : 0
  name              = var.backups.bucket
  object_storage_id = var.backups.object_storage_id
}

locals {
  # talos-backup reads the Talos API with a Talos service account. Talos
  # creates the Secret of the service account in the same namespace.
  etcd_backup_manifest = local.etcd_backup ? join("\n---\n", [
    yamlencode({
      apiVersion = "talos.dev/v1alpha1"
      kind       = "ServiceAccount"
      metadata   = { name = "talos-backup", namespace = "kube-system" }
      spec       = { roles = ["os:etcd:backup"] }
    }),
    yamlencode({
      apiVersion = "v1"
      kind       = "Secret"
      metadata   = { name = "talos-backup-s3", namespace = "kube-system" }
      type       = "Opaque"
      stringData = local.backup_credentials == null ? {} : {
        AWS_ACCESS_KEY_ID     = local.backup_credentials.access_key
        AWS_SECRET_ACCESS_KEY = local.backup_credentials.secret_key
      }
    }),
    yamlencode({
      apiVersion = "batch/v1"
      kind       = "CronJob"
      metadata   = { name = "talos-backup", namespace = "kube-system" }
      spec = {
        schedule                   = var.backups.etcd.schedule
        timeZone                   = "Etc/UTC"
        concurrencyPolicy          = "Forbid"
        successfulJobsHistoryLimit = 3
        failedJobsHistoryLimit     = 3
        jobTemplate = {
          spec = {
            backoffLimit = 3
            template = {
              spec = {
                restartPolicy = "OnFailure"
                # The job talks to the Talos API of the control plane nodes.
                tolerations = [{ key = "node-role.kubernetes.io/control-plane", operator = "Exists", effect = "NoSchedule" }]
                containers = [{
                  name       = "talos-backup"
                  image      = var.backups.etcd.image
                  command    = ["/talos-backup"]
                  workingDir = "/tmp"
                  envFrom    = [{ secretRef = { name = "talos-backup-s3" } }]
                  env = [for name, value in {
                    AWS_REGION               = local.backup_s3_region
                    CUSTOM_S3_ENDPOINT       = local.backup_s3_url
                    USE_PATH_STYLE           = "true"
                    BUCKET                   = local.backup_bucket
                    CLUSTER_NAME             = var.cluster_name
                    S3_PREFIX                = "etcd/${var.cluster_name}"
                    AGE_RECIPIENT_PUBLIC_KEY = join(",", var.backups.etcd.age_public_keys)
                    ENABLE_COMPRESSION       = "true"
                  } : { name = name, value = value }]
                  securityContext = {
                    runAsUser                = 1000
                    runAsGroup               = 1000
                    runAsNonRoot             = true
                    allowPrivilegeEscalation = false
                    readOnlyRootFilesystem   = true
                    capabilities             = { drop = ["ALL"] }
                    seccompProfile           = { type = "RuntimeDefault" }
                  }
                  volumeMounts = [
                    { name = "tmp", mountPath = "/tmp" },
                    { name = "talos", mountPath = "/.talos" },
                    { name = "talos-secrets", mountPath = "/var/run/secrets/talos.dev" },
                  ]
                }]
                volumes = [
                  { name = "tmp", emptyDir = {} },
                  { name = "talos", emptyDir = {} },
                  { name = "talos-secrets", secret = { secretName = "talos-backup" } },
                ]
              }
            }
          }
        }
      }
    }),
  ]) : ""

  backup_manifests = local.etcd_backup ? [{ name = "etcd-backup", contents = local.etcd_backup_manifest }] : []

  # Longhorn: the bucket becomes the default backup target, and a recurring
  # job backs up every volume of the group "default". Volumes without their
  # own recurring jobs belong to that group.
  longhorn_backup_values = local.longhorn_backup ? yamlencode({
    defaultBackupStore = {
      backupTarget                 = "s3://${local.backup_bucket}@${local.backup_s3_region}/longhorn/${var.cluster_name}/"
      backupTargetCredentialSecret = "longhorn-backup-s3"
    }
  }) : "{}"

  longhorn_backup_documents = local.longhorn_backup ? [
    yamlencode({
      apiVersion = "v1"
      kind       = "Secret"
      metadata   = { name = "longhorn-backup-s3", namespace = "longhorn-system" }
      type       = "Opaque"
      stringData = local.backup_credentials == null ? {} : {
        AWS_ACCESS_KEY_ID     = local.backup_credentials.access_key
        AWS_SECRET_ACCESS_KEY = local.backup_credentials.secret_key
        AWS_ENDPOINTS         = local.backup_s3_url
      }
    }),
    yamlencode({
      apiVersion = "longhorn.io/v1beta2"
      kind       = "RecurringJob"
      metadata   = { name = "backup", namespace = "longhorn-system" }
      spec = {
        name        = "backup"
        task        = "backup"
        cron        = var.backups.longhorn.schedule
        retain      = var.backups.longhorn.retain
        concurrency = 1
        groups      = ["default"]
        labels      = {}
      }
    }),
  ] : []
}
