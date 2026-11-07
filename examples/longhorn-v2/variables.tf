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

variable "control_plane_product_id" {
  description = "The Contabo product of the control plane node, for example \"V159\" (Cloud VPS Plus 4). Contabo bills the product every month."
  type        = string
}

variable "worker_product_id" {
  description = "The Contabo product of the three storage workers, for example \"V8\" (VDS S). Contabo bills the product every month."
  type        = string
}

variable "v2_size" {
  description = "The size of the raw partition for the V2 Data Engine on every storage worker, for example \"80GiB\"."
  type        = string
  default     = "80GiB"
}

variable "interrupt_mode" {
  description = "Whether the V2 Data Engine waits for work instead of keeping 2 CPU cores busy. Set it to true on a VPS, where the cores are shared."
  type        = bool
  default     = false
}

variable "admin_cidrs" {
  description = "Extra address ranges that may reach the Talos API and the Kubernetes API, for example [\"203.0.113.10/32\"]."
  type        = list(string)
  default     = []
}
