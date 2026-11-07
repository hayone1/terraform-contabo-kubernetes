variable "cluster_name" {
  description = "The name of the cluster, for example \"prod\"."
  type        = string
  default     = "prod"
}

variable "region" {
  description = "The Contabo region of all instances, for example \"EU\"."
  type        = string
  default     = "EU"
}

variable "control_plane_instance_ids" {
  description = "The instances that become control plane nodes, as a map from a short key to the Contabo instance id, for example { a = \"200000001\", b = \"200000002\", c = \"200000003\" }. Use an odd number of instances. The module erases them."
  type        = map(string)
}

variable "worker_product_id" {
  description = "The Contabo product of new workers, for example \"V91\"."
  type        = string
  default     = "V91"
}

variable "worker_count" {
  description = "The number of new workers that the module orders. Set 0 for no workers."
  type        = number
  default     = 2
}

variable "admin_cidrs" {
  description = "Extra address ranges that may reach the Talos API and the Kubernetes API."
  type        = list(string)
  default     = []
}
