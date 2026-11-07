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

variable "headscale_url" {
  description = "The address of your Headscale server, the server_url of its configuration, for example \"https://headscale.example.com\"."
  type        = string
}

variable "tailnet_domain" {
  description = "The MagicDNS domain of your Headscale tailnet, the dns.base_domain of the Headscale configuration, for example \"tailnet.example.com\"."
  type        = string
}

variable "admin_sources" {
  description = "The Headscale users, groups or tags that may reach the APIs of the node, for example [\"group:k8s-admins\"] or [\"alice@\"]. A group must exist in the policy."
  type        = list(string)
  default     = ["group:k8s-admins"]
}

variable "tag_owners" {
  description = "The Headscale users or groups that own the node tag tag:k8s-node in the policy, for example [\"group:k8s-admins\"]."
  type        = list(string)
  default     = ["group:k8s-admins"]
}

variable "manage_policy" {
  description = <<-EOT
    Whether Terraform owns the whole policy of the Headscale server. The Headscale server needs policy.mode = "database" in its configuration.
    With false, add the output tailscale_policy to your policy before the first apply.
    With true, Terraform replaces the whole policy with base_policy and the tags and grants of the example. Rules that are not in base_policy are lost.
  EOT
  type        = bool
  default     = false
}

variable "base_policy" {
  description = <<-EOT
    Other parts of the Headscale policy, as JSON, for example your groups. Only used with manage_policy = true.
    The default defines the group of admin_sources and tag_owners with the Headscale user "admin". Keep the policy as JSON without comments.
  EOT
  type        = string
  default     = "{\"groups\": {\"group:k8s-admins\": [\"admin@\"]}}"
}

variable "key_lifetime" {
  description = "How long new nodes can use the pre-auth key, for example \"90d\". Nodes that joined the tailnet stay in it after the key expires."
  type        = string
  default     = "90d"
}

variable "admin_cidrs" {
  description = "Extra address ranges that may reach the Talos API on the public addresses, for example [\"203.0.113.10/32\"]. New nodes get their first configuration through the Talos API."
  type        = list(string)
  default     = []
}
