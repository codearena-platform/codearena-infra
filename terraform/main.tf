resource "kubernetes_namespace" "codearena" {
  metadata {
    name = var.namespace
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

# Postgres Database
resource "helm_release" "postgres" {
  name       = "postgres"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "postgresql"
  namespace  = kubernetes_namespace.codearena.metadata[0].name
  wait       = true
  atomic     = true
  timeout    = 600

  set {
    name      = "auth.postgresPassword"
    value     = random_password.postgres.result
    sensitive = true
  }
  set {
    name  = "auth.database"
    value = "competition"
  }
}

# MongoDB. The Bitnami release "mongo" with chart "mongodb" exposes the service
# as "mongo-mongodb" (release name + chart name).
resource "helm_release" "mongodb" {
  name       = "mongo"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "mongodb"
  namespace  = kubernetes_namespace.codearena.metadata[0].name
  wait       = true
  atomic     = true
  timeout    = 600

  set {
    name      = "auth.rootPassword"
    value     = random_password.mongo.result
    sensitive = true
  }
  set {
    name  = "auth.enabled"
    value = "true"
  }
}

# Redis is deployed without authentication because codearena-core's realtime
# service does not support REDIS_PASSWORD yet. Do not expose it outside the
# namespace until password support is implemented.
resource "helm_release" "redis" {
  name       = "redis"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "redis"
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
}

# Kafka is provisioned for the event stream but is not consumed by the current
# services. Remove it from the deployment until a consumer is implemented.
resource "helm_release" "kafka" {
  name       = "kafka"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "kafka"
  namespace  = kubernetes_namespace.codearena.metadata[0].name
  wait       = true
  atomic     = true
  timeout    = 600

  set {
    name  = "numPartitions"
    value = "3"
  }
  set {
    name  = "kraft.enabled"
    value = "true"
  }
}
