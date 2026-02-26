resource "kubernetes_namespace" "codearena" {
  metadata {
    name = var.namespace
  }
}

# Postgres Database
resource "helm_release" "postgres" {
  name       = "postgres"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "postgresql"
  namespace  = kubernetes_namespace.codearena.metadata[0].name

  set {
    name  = "auth.postgresPassword"
    value = "password"
  }
  set {
    name  = "auth.database"
    value = "competition"
  }
}

# MongoDB
resource "helm_release" "mongodb" {
  name       = "mongo"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "mongodb"
  namespace  = kubernetes_namespace.codearena.metadata[0].name

  set {
    name  = "auth.rootPassword"
    value = "password"
  }
  
  # For simpler MVP setups
  set {
    name  = "auth.enabled"
    value = "false" 
  }
}

# Redis
resource "helm_release" "redis" {
  name       = "redis"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "redis"
  namespace  = kubernetes_namespace.codearena.metadata[0].name

  set {
    name  = "auth.enabled"
    value = "false"
  }
  set {
    name  = "architecture"
    value = "standalone"
  }
}

# Kafka
resource "helm_release" "kafka" {
  name       = "kafka"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "kafka"
  namespace  = kubernetes_namespace.codearena.metadata[0].name

  set {
    name  = "numPartitions"
    value = "3"
  }
  set {
    name  = "kraft.enabled"
    value = "true"
  }
}
