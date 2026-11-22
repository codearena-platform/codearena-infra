# Monitoring, alerting and centralized logs for CodeArena.
#
# Everything is installed in var.namespace (the same namespace as the app and
# its NetworkPolicies). k8s/monitoring-networkpolicy.yaml opens only the paths
# the monitoring components need. Rules and dashboards are provisioned through
# Helm values / a labelled ConfigMap instead of raw Prometheus CRDs so the
# repository's kubeconform validation stays schema-clean.

locals {
  prometheus_datasource = {
    type = "prometheus"
    uid  = "prometheus"
  }
  loki_datasource = {
    type = "loki"
    uid  = "loki"
  }

  # Annotation-based discovery of datastore exporters and any other in-namespace
  # endpoint that opts in with prometheus.io/scrape. kube-state-metrics and
  # cAdvisor (workload/container metrics) are already scraped by the stack.
  prometheus_scrape_configs = [
    {
      job_name = "codearena-datastore-exporters"
      kubernetes_sd_configs = [
        {
          role       = "endpoints"
          namespaces = { names = [var.namespace] }
        }
      ]
      relabel_configs = [
        {
          action        = "keep"
          source_labels = ["__meta_kubernetes_service_annotation_prometheus_io_scrape"]
          regex         = "true"
        },
        {
          action        = "replace"
          source_labels = ["__address__", "__meta_kubernetes_service_annotation_prometheus_io_port"]
          regex         = "([^:]+)(:[0-9]+)?;([0-9]+)"
          replacement   = "$1:$3"
          target_label  = "__address__"
        },
        {
          action        = "replace"
          source_labels = ["__meta_kubernetes_service_annotation_prometheus_io_path"]
          regex         = "(.+)"
          target_label  = "__metrics_path__"
        },
        {
          action      = "labelmap"
          regex       = "__meta_kubernetes_service_label_(.+)"
          replacement = "$1"
        },
        {
          action        = "replace"
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        },
        {
          action        = "replace"
          source_labels = ["__meta_kubernetes_service_name"]
          target_label  = "service"
        },
        {
          action        = "replace"
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
      ]
    }
  ]

  # Alert rules. PromQL assumes kube-state-metrics (pod/PVC/Job metrics), the
  # three exporter releases below (pg_up/mongodb_up/redis_up), and an
  # ingress-nginx controller that exports nginx_ingress_controller_requests
  # with the service annotation above. All thresholds are documented in the
  # on-call runbook so the on-call engineer knows what each alert means.
  codearena_alert_rules = {
    "codearena-operational-alerts" = {
      groups = [
        {
          name = "codearena-pods"
          rules = [
            {
              alert  = "CodeArenaPodRestarts"
              expr   = "sum by (namespace, pod, container) (increase(kube_pod_container_status_restarts_total{namespace=\"${var.namespace}\"}[15m])) >= 3"
              for    = "5m"
              labels = { severity = "warning", team = "codearena" }
              annotations = {
                summary     = "Container restarted repeatedly ({{ $labels.pod }}/{{ $labels.container }})"
                description = "More than three restarts in 15 minutes in namespace {{ $labels.namespace }}. Check the CrashLoopBackOff alert and Loki logs."
                runbook_url = "https://github.com/codearena-platform/codearena-infra/blob/main/docs/oncall-runbook.md#pod-restarts--crashloopbackoff"
              }
            },
            {
              alert  = "CodeArenaPodCrashLoopBackOff"
              expr   = "kube_pod_container_status_waiting_reason{namespace=\"${var.namespace}\", reason=\"CrashLoopBackOff\"} == 1"
              for    = "5m"
              labels = { severity = "critical", team = "codearena" }
              annotations = {
                summary     = "Container is in CrashLoopBackOff ({{ $labels.pod }})"
                description = "Pod {{ $labels.pod }} in {{ $labels.namespace }} has been waiting with reason CrashLoopBackOff for five minutes."
                runbook_url = "https://github.com/codearena-platform/codearena-infra/blob/main/docs/oncall-runbook.md#pod-restarts--crashloopbackoff"
              }
            }
          ]
        },
        {
          name = "codearena-persistence"
          rules = [
            {
              alert  = "CodeArenaPVCUsageHigh"
              expr   = "(kubelet_volume_stats_used_bytes{namespace=\"${var.namespace}\"} / clamp_min(kubelet_volume_stats_capacity_bytes{namespace=\"${var.namespace}\"}, 1)) > 0.85"
              for    = "15m"
              labels = { severity = "warning", team = "codearena" }
              annotations = {
                summary     = "PVC above 85% capacity ({{ $labels.persistentvolumeclaim }})"
                description = "PVC {{ $labels.persistentvolumeclaim }} in {{ $labels.namespace }} is more than 85% full. Includes datastore, backup and Core SQLite volumes."
                runbook_url = "https://github.com/codearena-platform/codearena-infra/blob/main/docs/oncall-runbook.md#pvc-usage"
              }
            }
          ]
        },
        {
          name = "codearena-jobs"
          rules = [
            {
              alert  = "CodeArenaSchemaMigrationJobFailed"
              expr   = "sum by (namespace, job_name) (kube_job_status_failed{namespace=\"${var.namespace}\", job_name=~\"schema-migrations-.*\"}) > 0"
              for    = "0m"
              labels = { severity = "critical", team = "codearena" }
              annotations = {
                summary     = "Schema migration Job failed ({{ $labels.job_name }})"
                description = "A schema-migrations Job failed in {{ $labels.namespace }}. Do not roll out new application images until the migration has been fixed and re-run."
                runbook_url = "https://github.com/codearena-platform/codearena-infra/blob/main/docs/oncall-runbook.md#failed-migration-or-backup-jobs"
              }
            },
            {
              alert  = "CodeArenaBackupJobFailed"
              expr   = "sum by (namespace, job_name) (kube_job_status_failed{namespace=\"${var.namespace}\", job_name=~\"datastore-backup-.*\"}) > 0"
              for    = "0m"
              labels = { severity = "critical", team = "codearena" }
              annotations = {
                summary     = "Datastore backup Job failed ({{ $labels.job_name }})"
                description = "A datastore-backup Job failed in {{ $labels.namespace }}. The daily dump may be missing; check the last successful files and the backup PVC."
                runbook_url = "https://github.com/codearena-platform/codearena-infra/blob/main/docs/oncall-runbook.md#failed-migration-or-backup-jobs"
              }
            }
          ]
        },
        {
          name = "codearena-ingress"
          rules = [
            {
              alert  = "CodeArenaIngressHighErrorRate"
              expr   = "sum(rate(nginx_ingress_controller_requests{namespace=\"${var.ingress_controller_namespace}\", host=\"${var.ingress_host}\", status=~\"5..\"}[5m])) / clamp_min(sum(rate(nginx_ingress_controller_requests{namespace=\"${var.ingress_controller_namespace}\", host=\"${var.ingress_host}\"}[5m])), 1) > 0.05"
              for    = "5m"
              labels = { severity = "critical", team = "codearena" }
              annotations = {
                summary     = "Ingress 5xx ratio above 5% for ${var.ingress_host}"
                description = "More than 5% of requests to {{ $labels.host }} returned 5xx over five minutes. Requires ingress-nginx metrics and a Service annotation on its metrics endpoint."
                runbook_url = "https://github.com/codearena-platform/codearena-infra/blob/main/docs/oncall-runbook.md#ingress-error-rate"
              }
            }
          ]
        }
      ]
    }
  }

  # Generic routing tree. The concrete webhook / integration key are injected
  # with set_sensitive below; empty values resolve to disabled placeholders so
  # Alertmanager still starts with a valid configuration.
  alertmanager_config = {
    route = {
      receiver        = "codearena-slack"
      group_by        = ["namespace", "alertname"]
      group_wait      = "30s"
      group_interval  = "5m"
      repeat_interval = "4h"
      routes = [
        {
          receiver = "codearena-pagerduty"
          matchers = ["severity = critical"]
        },
        {
          receiver = "codearena-slack"
          matchers = ["severity = warning"]
        }
      ]
    }
    receivers = [
      {
        name = "codearena-slack"
        slack_configs = [
          {
            api_url       = "http://127.0.0.1:1/slack-disabled"
            channel       = "#${var.alert_slack_channel}"
            send_resolved = true
            title         = "[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}"
          }
        ]
      },
      {
        name = "codearena-pagerduty"
        pagerduty_configs = [
          {
            routing_key   = "disabled"
            severity      = "{{ .CommonLabels.severity }}"
            send_resolved = true
          }
        ]
      },
      {
        name = "null"
      }
    ]
    inhibit_rules = [
      {
        source_matchers = ["alertname = CodeArenaPodCrashLoopBackOff"]
        target_matchers = ["alertname = CodeArenaPodRestarts"]
        equal           = ["namespace", "pod"]
      }
    ]
  }

  codearena_dashboard = jsonencode({
    uid           = "codearena-overview"
    title         = "CodeArena Operational Overview"
    tags          = ["codearena", "operations"]
    schemaVersion = 39
    refresh       = "30s"
    time          = { from = "now-1h", to = "now" }
    panels = [
      {
        type    = "timeseries"
        title   = "Pod restarts (15m)"
        gridPos = { h = 8, w = 12, x = 0, y = 0 }
        targets = [
          {
            refId        = "A"
            datasource   = local.prometheus_datasource
            expr         = "sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total{namespace=\"${var.namespace}\"}[15m]))"
            legendFormat = "{{ pod }}"
          }
        ]
        fieldConfig = { defaults = { unit = "short" }, overrides = [] }
      },
      {
        type    = "timeseries"
        title   = "Pods in CrashLoopBackOff"
        gridPos = { h = 8, w = 12, x = 12, y = 0 }
        targets = [
          {
            refId        = "A"
            datasource   = local.prometheus_datasource
            expr         = "sum by (namespace, pod) (kube_pod_container_status_waiting_reason{namespace=\"${var.namespace}\", reason=\"CrashLoopBackOff\"})"
            legendFormat = "{{ pod }}"
          }
        ]
        fieldConfig = { defaults = { unit = "short" }, overrides = [] }
      },
      {
        type    = "timeseries"
        title   = "PVC usage by volume (%)"
        gridPos = { h = 8, w = 12, x = 0, y = 8 }
        targets = [
          {
            refId        = "A"
            datasource   = local.prometheus_datasource
            expr         = "100 * (kubelet_volume_stats_used_bytes{namespace=\"${var.namespace}\"} / clamp_min(kubelet_volume_stats_capacity_bytes{namespace=\"${var.namespace}\"}, 1))"
            legendFormat = "{{ persistentvolumeclaim }}"
          }
        ]
        fieldConfig = { defaults = { unit = "percent" }, overrides = [] }
      },
      {
        type    = "timeseries"
        title   = "Ingress 5xx rate"
        gridPos = { h = 8, w = 12, x = 12, y = 8 }
        targets = [
          {
            refId        = "A"
            datasource   = local.prometheus_datasource
            expr         = "sum(rate(nginx_ingress_controller_requests{namespace=\"${var.ingress_controller_namespace}\", host=\"${var.ingress_host}\", status=~\"5..\"}[5m]))"
            legendFormat = "5xx"
          }
        ]
        fieldConfig = { defaults = { unit = "reqps" }, overrides = [] }
      },
      {
        type    = "timeseries"
        title   = "Failed migration / backup Jobs"
        gridPos = { h = 8, w = 12, x = 0, y = 16 }
        targets = [
          {
            refId        = "A"
            datasource   = local.prometheus_datasource
            expr         = "sum by (job_name) (kube_job_status_failed{namespace=\"${var.namespace}\", job_name=~\"schema-migrations-.*|datastore-backup-.*\"})"
            legendFormat = "{{ job_name }}"
          }
        ]
        fieldConfig = { defaults = { unit = "short" }, overrides = [] }
      },
      {
        type    = "timeseries"
        title   = "Datastore exporter availability"
        gridPos = { h = 8, w = 12, x = 12, y = 16 }
        targets = [
          {
            refId        = "A"
            datasource   = local.prometheus_datasource
            expr         = "pg_up{namespace=\"${var.namespace}\"}"
            legendFormat = "postgres"
          },
          {
            refId        = "B"
            datasource   = local.prometheus_datasource
            expr         = "mongodb_up{namespace=\"${var.namespace}\"}"
            legendFormat = "mongodb"
          },
          {
            refId        = "C"
            datasource   = local.prometheus_datasource
            expr         = "redis_up{namespace=\"${var.namespace}\"}"
            legendFormat = "redis"
          }
        ]
        fieldConfig = { defaults = { unit = "short", min = 0, max = 1 }, overrides = [] }
      },
      {
        type    = "logs"
        title   = "Application errors (Loki)"
        gridPos = { h = 10, w = 24, x = 0, y = 24 }
        targets = [
          {
            refId      = "A"
            datasource = local.loki_datasource
            expr       = "{namespace=\"${var.namespace}\"} |= \"error\""
          }
        ]
      }
    ]
  })

  kube_prometheus_values = {
    additionalPrometheusRulesMap = local.codearena_alert_rules
    alertmanager = {
      config = local.alertmanager_config
    }
    grafana = {
      adminUser = "admin"
      sidecar = {
        dashboards = {
          enabled         = true
          label           = "grafana_dashboard"
          labelValue      = "1"
          searchNamespace = "ALL"
        }
      }
      additionalDataSources = [
        {
          name      = "Loki"
          type      = "loki"
          uid       = "loki"
          access    = "proxy"
          url       = "http://loki:3100"
          isDefault = false
          editable  = false
        }
      ]
      persistence = {
        enabled          = true
        type             = "sts"
        size             = "10Gi"
        storageClassName = var.storage_class
      }
    }
    prometheus = {
      prometheusSpec = {
        retention               = "15d"
        additionalScrapeConfigs = local.prometheus_scrape_configs
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              accessModes      = ["ReadWriteOnce"]
              storageClassName = var.storage_class
              resources = {
                requests = { storage = var.metrics_pvc_size }
              }
            }
          }
        }
      }
    }
  }

  loki_values = {
    loki = {
      auth_enabled = false
      commonConfig = {
        path_prefix        = "/var/loki"
        replication_factor = 1
        compactor_address  = "http://loki:3100"
      }
      limits_config = {
        reject_old_samples            = true
        reject_old_samples_max_age    = var.log_retention_period
        retention_period              = var.log_retention_period
        max_cache_freshness_per_query = "10m"
        split_queries_by_interval     = "15m"
      }
      compactor = {
        retention_enabled             = true
        retention_delete_delay        = "2h"
        retention_delete_worker_count = 10
      }
      storage = {
        type = "filesystem"
        filesystem = {
          chunks_directory = "/var/loki/chunks"
          rules_directory  = "/var/loki/rules"
        }
      }
      schemaConfig = {
        configs = [
          {
            from         = "2024-01-01"
            store        = "tsdb"
            object_store = "filesystem"
            schema       = "v13"
            index = {
              prefix = "index_"
              period = "24h"
            }
          }
        ]
      }
      storage_config = {
        filesystem = { directory = "/var/loki/chunks" }
        tsdb_shipper = {
          active_index_directory = "/var/loki/boltdb-shipper-active"
          cache_location         = "/var/loki/boltdb-shipper-cache"
        }
      }
    }
    singleBinary = {
      replicas = 1
      persistence = {
        enabled      = true
        size         = var.log_pvc_size
        storageClass = var.storage_class
      }
    }
    # Keep Loki's own dashboards, but do not require Prometheus Operator CRDs
    # to exist before this release is installed.
    monitoring = {
      dashboards     = { enabled = true }
      rules          = { enabled = false }
      serviceMonitor = { enabled = false }
    }
    lokiCanary = { enabled = false }
  }

  prometheus_labels = {
    "prometheus.io/scrape" = "true"
    "prometheus.io/port"   = "9187"
    "prometheus.io/path"   = "/metrics"
  }
  mongodb_exporter_labels = {
    "prometheus.io/scrape" = "true"
    "prometheus.io/port"   = "9216"
    "prometheus.io/path"   = "/metrics"
  }
  redis_exporter_labels = {
    "prometheus.io/scrape" = "true"
    "prometheus.io/port"   = "9121"
    "prometheus.io/path"   = "/metrics"
  }
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version
  namespace  = var.namespace
  wait       = true
  atomic     = true
  timeout    = 900

  values = [yamlencode(local.kube_prometheus_values)]

  set_sensitive {
    name  = "grafana.adminPassword"
    value = random_password.grafana_admin.result
  }
  set_sensitive {
    name  = "alertmanager.config.receivers[0].slack_configs[0].api_url"
    value = var.alert_slack_webhook_url == "" ? "http://127.0.0.1:1/slack-disabled" : var.alert_slack_webhook_url
  }
  set_sensitive {
    name  = "alertmanager.config.receivers[1].pagerduty_configs[0].routing_key"
    value = var.alert_pagerduty_routing_key == "" ? "disabled" : var.alert_pagerduty_routing_key
  }

  depends_on = [kubernetes_namespace.codearena]
}

# The Grafana dashboard sidecar watches ConfigMaps with this label. Keeping the
# dashboard here (rather than in k8s/) avoids adding an unvalidatable CRD and
# lets the dashboard reference var.namespace/var.ingress_host.
resource "kubernetes_config_map" "codearena_dashboard" {
  metadata {
    name      = "codearena-overview-dashboard"
    namespace = var.namespace
    labels = {
      "grafana_dashboard"         = "1"
      "app.kubernetes.io/part-of" = "codearena"
    }
  }

  data = {
    "codearena-overview.json" = local.codearena_dashboard
  }

  depends_on = [kubernetes_namespace.codearena]
}

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.loki_version
  namespace  = var.namespace
  wait       = true
  atomic     = true
  timeout    = 900

  values = [yamlencode(local.loki_values)]

  depends_on = [kubernetes_namespace.codearena]
}

resource "helm_release" "promtail" {
  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  version    = var.promtail_version
  namespace  = var.namespace
  wait       = true
  atomic     = true
  timeout    = 600

  set {
    name  = "config.clients[0].url"
    value = "http://loki:3100/loki/api/v1/push"
  }
  set {
    name  = "config.snippets.addScrapeJobLabel"
    value = "true"
  }
  set {
    name  = "config.snippets.extraRelabelConfigs[0].target_label"
    value = "environment"
  }
  set {
    name  = "config.snippets.extraRelabelConfigs[0].replacement"
    value = var.environment
  }
  set {
    name  = "config.snippets.extraRelabelConfigs[1].target_label"
    value = "source"
  }
  set {
    name  = "config.snippets.extraRelabelConfigs[1].replacement"
    value = "codearena"
  }

  depends_on = [helm_release.loki, kubernetes_namespace.codearena]
}

# Datastore metrics. Connection strings come from the existing application
# Secret, so no credentials are duplicated in Terraform state or Helm values.
resource "helm_release" "postgres_exporter" {
  name       = "postgres-exporter"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-postgres-exporter"
  version    = var.postgres_exporter_version
  namespace  = var.namespace
  wait       = true
  atomic     = true
  timeout    = 600

  values = [yamlencode({
    config = {
      datasourceSecret = {
        name = "codearena-secrets"
        key  = "POSTGRES_DSN"
      }
    }
    service = {
      type        = "ClusterIP"
      port        = 9187
      annotations = local.prometheus_labels
    }
    serviceMonitor = { enabled = false }
  })]

  depends_on = [kubernetes_secret.app, kubernetes_namespace.codearena]
}

resource "helm_release" "mongodb_exporter" {
  name       = "mongodb-exporter"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-mongodb-exporter"
  version    = var.mongodb_exporter_version
  namespace  = var.namespace
  wait       = true
  atomic     = true
  timeout    = 600

  values = [yamlencode({
    existingSecret = {
      name = "codearena-secrets"
      key  = "MONGO_URI"
    }
    service = {
      type        = "ClusterIP"
      port        = 9216
      portName    = "metrics"
      annotations = local.mongodb_exporter_labels
    }
    serviceMonitor = { enabled = false }
  })]

  depends_on = [kubernetes_secret.app, kubernetes_namespace.codearena]
}

resource "helm_release" "redis_exporter" {
  name       = "redis-exporter"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-redis-exporter"
  version    = var.redis_exporter_version
  namespace  = var.namespace
  wait       = true
  atomic     = true
  timeout    = 600

  values = [yamlencode({
    redisAddressConfig = {
      enabled  = true
      isSecret = true
      source = {
        name = "codearena-secrets"
        key  = "REDIS_ADDR"
      }
    }
    service = {
      type        = "ClusterIP"
      port        = 9121
      annotations = local.redis_exporter_labels
    }
    serviceMonitor = { enabled = false }
  })]

  depends_on = [kubernetes_secret.app, kubernetes_namespace.codearena]
}
