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

variable "tailnet_domain" {
  description = "The MagicDNS domain of your tailnet, for example \"tail1234.ts.net\". The Tailscale admin console shows the domain on the DNS page."
  type        = string
}

variable "manage_tailnet" {
  description = <<-EOT
    Whether Terraform owns the whole tailnet policy and turns on HTTPS for the tailnet. The API server proxy of the operator needs HTTPS.
    With false, add the output tailscale_policy to your tailnet policy and turn on HTTPS in the admin console before the first apply.
    With true, Terraform replaces the whole policy with the policy of this example and base_policy. Rules that are not in base_policy are lost.
  EOT
  type        = bool
  default     = false
}

variable "base_policy" {
  description = <<-EOT
    Other parts of the tailnet policy, as JSON, for example the policy that you have today. Only used with manage_tailnet = true.
    The example merges its own tags and grants into it. Keep the policy as JSON without comments.
  EOT
  type        = string
  default     = "{}"
}

variable "admin_sources" {
  description = "The Tailscale users, groups or tags that may use the cluster as admins, for example [\"group:k8s-admins\"]. The default is every admin of the tailnet."
  type        = list(string)
  default     = ["autogroup:admin"]
}

variable "admin_cidrs" {
  description = "Extra address ranges that may reach the Talos API on the public addresses, for example [\"203.0.113.10/32\"]. New nodes get their first configuration through the Talos API."
  type        = list(string)
  default     = []
}
