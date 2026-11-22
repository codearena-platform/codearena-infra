resource "kubernetes_namespace" "codearena" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "codearena"
    }
  }
}

# Credentials are generated once and kept in Terraform state. The state backend
# must therefore be encrypted and access-controlled (see README).
resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "random_password" "mongo" {
  length  = 32
  special = false
}

resource "random_password" "jwt" {
  length  = 64
  special = false
}

resource "random_id" "encrypter" {
  byte_length = 32
}

# Application configuration consumed by the workloads in k8s/. Connection
# strings are composed here so that the service hostnames stay in one place.
resource "kubernetes_secret" "app" {
  metadata {
    name      = "codearena-secrets"
    namespace = kubernetes_namespace.codearena.metadata[0].name
  }

  type = "Opaque"

  data = {
    POSTGRES_DSN  = "postgres://postgres:${random_password.postgres.result}@postgres-postgresql:5432/competition?sslmode=disable"
    MONGO_URI     = "mongodb://root:${random_password.mongo.result}@mongo-mongodb:27017/?authSource=admin"
    JWT_SECRET    = random_password.jwt.result
    ENCRYPTER_KEY = random_id.encrypter.hex
    REDIS_ADDR    = "redis-master:6379"
  }
}

# Public entry point. The gateway Service is ClusterIP; TLS is terminated here.
# The TLS Secret must be created out of band (see README) and kept in sync with
# the certificate for var.ingress_host.
resource "kubernetes_ingress_v1" "gateway" {
  metadata {
    name      = "gateway"
    namespace = kubernetes_namespace.codearena.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
    }
  }

  spec {
    ingress_class_name = var.ingress_class_name

    tls {
      hosts       = [var.ingress_host]
      secret_name = var.ingress_tls_secret_name
    }

    rule {
      host = var.ingress_host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "gateway"
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }
}

# Postgres Database
resource "helm_release" "postgres" {
  name       = "postgres"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "postgresql"
  version    = "16.2.2"
  namespace  = kubernetes_namespace.codearena.metadata[0].name
  wait       = true
  atomic     = true
  timeout    = 600

  set_sensitive {
    name  = "auth.postgresPassword"
    value = random_password.postgres.result
  }
  set {
    name  = "auth.database"
    value = "competition"
  }
  set {
    name  = "primary.persistence.enabled"
    value = "true"
  }
  set {
    name  = "primary.persistence.size"
    value = var.postgres_pvc_size
  }
  set {
    name  = "primary.persistence.storageClass"
    value = var.storage_class
  }
  set {
    name  = "primary.service.type"
    value = "ClusterIP"
  }
}

# MongoDB. The Bitnami release "mongo" with chart "mongodb" exposes the service
# as "mongo-mongodb" (release name + chart name).
resource "helm_release" "mongodb" {
  name       = "mongo"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "mongodb"
  version    = "16.3.2"
  namespace  = kubernetes_namespace.codearena.metadata[0].name
  wait       = true
  atomic     = true
  timeout    = 600

  set_sensitive {
    name  = "auth.rootPassword"
    value = random_password.mongo.result
  }
  set {
    name  = "auth.enabled"
    value = "true"
  }
  set {
    name  = "persistence.enabled"
    value = "true"
  }
  set {
    name  = "persistence.size"
    value = var.mongodb_pvc_size
  }
  set {
    name  = "persistence.storageClass"
    value = var.storage_class
  }
  set {
    name  = "service.type"
    value = "ClusterIP"
  }
}

# Redis is deployed without authentication because codearena-core's realtime
# service does not support REDIS_PASSWORD yet. Do not expose it outside the
# namespace until password support is implemented.
resource "helm_release" "redis" {
  name       = "redis"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "redis"
  version    = "20.6.1"
  namespace  = kubernetes_namespace.codearena.metadata[0].name
  wait       = true
  atomic     = true
  timeout    = 600

  set {
    name  = "auth.enabled"
    value = "false"
  }
  set {
    name  = "architecture"
    value = "standalone"
  }
  set {
    name  = "master.persistence.enabled"
    value = "true"
  }
  set {
    name  = "master.persistence.size"
    value = var.redis_pvc_size
  }
  set {
    name  = "master.persistence.storageClass"
    value = var.storage_class
  }
  set {
    name  = "master.service.type"
    value = "ClusterIP"
  }
}

# Kafka is provisioned for the event stream but is not consumed by the current
# services. Remove it from the deployment until a consumer is implemented.
resource "helm_release" "kafka" {
  name       = "kafka"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "kafka"
  version    = "31.1.1"
  namespace  = kubernetes_namespace.codearena.metadata[0].name
  wait       = true
  atomic     = true
  timeout    = 600

  set {
    name  = "provisioning.numPartitions"
    value = "3"
  }
  set {
    name  = "kraft.enabled"
    value = "true"
  }
  set {
    name  = "controller.persistence.enabled"
    value = "true"
  }
  set {
    name  = "controller.persistence.size"
    value = var.kafka_pvc_size
  }
  set {
    name  = "controller.persistence.storageClass"
    value = var.storage_class
  }
  set {
    name  = "broker.persistence.enabled"
    value = "true"
  }
  set {
    name  = "broker.persistence.size"
    value = var.kafka_pvc_size
  }
  set {
    name  = "broker.persistence.storageClass"
    value = var.storage_class
  }
  set {
    name  = "service.type"
    value = "ClusterIP"
  }
}
