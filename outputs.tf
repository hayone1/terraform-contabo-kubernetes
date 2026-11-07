output "kubeconfig" {
  description = "A kubeconfig file with cluster-admin rights. The file uses the public Kubernetes API address. Keep the file secret."
  value       = local.kubeconfig
  sensitive   = true
  depends_on  = [terraform_data.sync_kubernetes]
}

output "kubernetes_client" {
  description = "The Kubernetes API address and the admin credentials as separate values, for example for the kubernetes and helm providers. The certificates and the key are PEM text."
  value = {
    host                   = local.kubernetes_api_url
    cluster_ca_certificate = base64decode(local.kubernetes_client.ca_certificate)
    client_certificate     = base64decode(local.kubernetes_client.client_certificate)
    client_key             = base64decode(local.kubernetes_client.client_key)
  }
  sensitive  = true
  depends_on = [terraform_data.sync_kubernetes]
}

output "talosconfig" {
  description = "A talosconfig file for talosctl with admin rights on every node. Keep the file secret."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubernetes_api_url" {
  description = "The address of the Kubernetes API in the kubeconfig. In the tailscale mode, the address uses the tailnet name of the first control plane node."
  value       = local.kubernetes_api_url
}

output "tailscale" {
  description = "The tailnet names of the nodes with the Tailscale node agent, and the address of the API server proxy of the Tailscale operator. The value is null when Tailscale is off."
  value = local.tailscale_agent || local.tailscale_operator ? {
    nodes            = { for key, name in local.tailnet_names : local.nodes[key].name => name }
    api_server_proxy = local.tailscale_operator ? "https://${local.tailscale_operator_hostname}.${var.tailscale.tailnet_domain}" : null
  } : null
}

output "tailscale_policy" {
  description = "Tags and grants that the tailnet policy needs for the Tailscale settings of the module, as JSON. Add them to your tailnet policy. The module never changes the policy."
  value       = local.tailscale_agent || local.tailscale_operator ? jsonencode(local.tailscale_policy) : null
}

output "nodes" {
  description = "Every node with its role, pool, Contabo instance id and addresses."
  value = {
    for key, node in local.nodes : node.name => {
      role         = node.role
      pool         = node.pool
      instance_id  = contabo_instance.node[key].id
      product_id   = contabo_instance.node[key].product_id
      adopted      = node.adopted
      public_ipv4  = local.public_ipv4[key]
      private_ipv4 = local.private_ipv4[key]
    }
  }
}

output "private_network" {
  description = "The id and the address range of the private network of the cluster."
  value = {
    id      = local.private_network_id
    cidr    = local.private_network_cidr
    managed = var.private_network.existing_id == null
  }
}

output "contabo_firewall_id" {
  description = "The id of the Contabo firewall, or null when the module does not manage a firewall."
  value       = var.contabo_firewall.enabled ? contabo_firewall.this[0].id : null
}

output "admin_cidrs" {
  description = "The address ranges that may reach the Talos API and the Kubernetes API."
  value       = local.admin_cidrs
}

output "vnc" {
  description = "The VNC console address and password of every node. Contabo keeps the console on, so keep the passwords secret."
  value = {
    for key, vnc in contabo_instance_vnc.node : local.nodes[key].name => {
      address  = "${vnc.vnc_ip}:${vnc.vnc_port}"
      password = random_password.vnc[key].result
    }
  }
  sensitive = true
}

output "service_account_issuer" {
  description = "The issuer of the service account tokens of the cluster."
  value       = var.workload_identity.enabled ? module.workload_identity[0].issuer_url : var.service_account_issuer
}

output "workload_identity" {
  description = "Values for the cloud side of workload identity, for example for an Entra ID federated identity credential. The value is null when workload identity is off."
  value = var.workload_identity.enabled ? {
    issuer_url  = module.workload_identity[0].issuer_url
    key_ids     = module.workload_identity[0].key_ids
    bucket_name = module.workload_identity[0].bucket_name
    azure       = module.workload_identity[0].azure
  } : null
}

output "talos_version" {
  description = "The Talos version of the nodes."
  value       = var.talos_version
}

output "kubernetes_version" {
  description = "The Kubernetes version of the cluster."
  value       = var.kubernetes_version
}

output "talos_installer_images" {
  description = "The Talos installer image of every node. Use the image of a node for a manual \"talosctl upgrade\"."
  value       = { for key, node in local.nodes : node.name => local.installer_image[key] }
}
