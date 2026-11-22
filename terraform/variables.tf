variable "namespace" {
  description = "The Kubernetes namespace to deploy infrastructure"
  type        = string
  default     = "codearena"
}

variable "environment" {
  description = "The environment code (e.g., dev, prod)"
  type        = string
  default     = "dev"
}

variable "kube_config_path" {
  description = "Path to the kubeconfig file. Set to null when using in-cluster credentials or OIDC in CI."
  type        = string
  default     = "~/.kube/config"
}

variable "ingress_host" {
  description = "Public DNS name for the gateway Ingress. DNS must point at the ingress controller."
  type        = string
  default     = "codearena.example.com"
}

variable "ingress_tls_secret_name" {
  description = "Name of an existing TLS Secret in the namespace containing the certificate for ingress_host."
  type        = string
  default     = "codearena-tls"
}

variable "ingress_class_name" {
  description = "Ingress class handled by the installed controller (nginx by default)."
  type        = string
  default     = "nginx"
}

variable "storage_class" {
  description = "StorageClass used by all datastore PVCs. Must exist and support dynamic provisioning."
  type        = string
  default     = "standard"
}

variable "postgres_pvc_size" {
  description = "Size of the PostgreSQL data PVC."
  type        = string
  default     = "20Gi"
}

variable "mongodb_pvc_size" {
  description = "Size of the MongoDB data PVC."
  type        = string
  default     = "20Gi"
}

variable "redis_pvc_size" {
  description = "Size of the Redis data PVC."
  type        = string
  default     = "10Gi"
}

variable "ws_allowed_origins" {
  description = "Comma-separated browser origins allowed to open Core realtime WebSockets. Empty uses same-origin fallback."
  type        = string
  default     = ""
}
