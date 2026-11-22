# The backup CronJob reads these keys through an optional Secret reference. If
# the variable is unset, no Secret is created and the Job keeps local dumps.
# Credentials end up in Terraform state, so the encrypted remote backend is
# mandatory whenever this variable is used (see README).
resource "kubernetes_secret" "backup_s3" {
  count = var.backup_s3 == null ? 0 : 1

  metadata {
    name      = "codearena-backup-s3"
    namespace = kubernetes_namespace.codearena.metadata[0].name
  }

  type = "Opaque"

  data = {
    endpoint   = var.backup_s3.endpoint
    bucket     = var.backup_s3.bucket
    region     = var.backup_s3.region
    prefix     = var.backup_s3.prefix
    access_key = var.backup_s3.access_key
    secret_key = var.backup_s3.secret_key
  }
}
