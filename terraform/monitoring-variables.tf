# Monitoring, alerting and log aggregation inputs.
#
# All charts are pinned to exact versions so a `terraform apply` is reproducible.
# Combine these with the shared `namespace`/`environment` variables in variables.tf.

variable "kube_prometheus_stack_version" {
  description = "Pinned kube-prometheus-stack chart version (Prometheus, Alertmanager, Grafana)."
  type        = string
  default     = "70.0.0"
}

variable "loki_version" {
  description = "Pinned Grafana Loki chart version for centralized logs."
  type        = string
  default     = "5.48.0"
}

variable "promtail_version" {
  description = "Pinned Grafana Promtail chart version for container log collection."
  type        = string
  default     = "6.17.1"
}

variable "postgres_exporter_version" {
  description = "Pinned prometheus-postgres-exporter chart version."
  type        = string
  default     = "8.3.0"
}

variable "mongodb_exporter_version" {
  description = "Pinned prometheus-mongodb-exporter chart version."
  type        = string
  default     = "3.23.2"
}

variable "redis_exporter_version" {
  description = "Pinned prometheus-redis-exporter chart version."
  type        = string
  default     = "6.38.0"
}

variable "log_retention_period" {
  description = "Loki retention period for centralized logs (Prometheus duration syntax). Seven days covers typical incident investigations."
  type        = string
  default     = "168h"
}

variable "metrics_pvc_size" {
  description = "PVC size for Prometheus time-series storage."
  type        = string
  default     = "20Gi"
}

variable "log_pvc_size" {
  description = "PVC size for Loki log chunks and indexes."
  type        = string
  default     = "20Gi"
}

variable "ingress_controller_namespace" {
  description = "Namespace of the ingress-nginx controller exporting nginx_ingress_controller_requests."
  type        = string
  default     = "ingress-nginx"
}

variable "alert_slack_channel" {
  description = "Slack channel (without #) used by the generic alert receiver."
  type        = string
  default     = "codearena-alerts"
}

variable "alert_slack_webhook_url" {
  description = "Slack incoming webhook URL for non-critical alerts. Leave empty to keep the receiver disabled until the secret is supplied."
  type        = string
  sensitive   = true
  default     = ""
}

variable "alert_pagerduty_routing_key" {
  description = "PagerDuty Events API v2 integration key for critical alerts. Leave empty to keep the receiver disabled until the secret is supplied."
  type        = string
  sensitive   = true
  default     = ""
}
