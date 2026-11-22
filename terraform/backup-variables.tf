variable "backup_s3" {
  description = "Optional S3-compatible target for off-cluster backups. Leave null to keep dumps on the in-cluster PVC only."
  type = object({
    endpoint   = string
    bucket     = string
    region     = optional(string, "us-east-1")
    prefix     = optional(string, "codearena")
    access_key = string
    secret_key = string
  })
  default   = null
  sensitive = true
}
