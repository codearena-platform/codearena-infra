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
