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
