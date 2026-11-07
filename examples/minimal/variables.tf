variable "cluster_name" {
  description = "The name of the cluster, for example \"demo\"."
  type        = string
  default     = "demo"
}

variable "region" {
  description = "The Contabo region, for example \"EU\"."
  type        = string
  default     = "EU"
}

variable "product_id" {
  description = "The Contabo product of the node, for example \"V91\" (Cloud VPS 10). Contabo bills the product every month."
  type        = string
}

variable "admin_cidrs" {
  description = "Extra address ranges that may reach the Talos API and the Kubernetes API, for example [\"203.0.113.10/32\"]."
  type        = list(string)
  default     = []
}
