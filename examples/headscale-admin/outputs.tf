output "kubeconfig" {
  description = "An admin kubeconfig that uses the tailnet name of the control plane node. Save it with: terraform output -raw kubeconfig > kubeconfig"
  value       = module.kubernetes.kubeconfig
  sensitive   = true
}

output "talosconfig" {
  description = "Save it with: terraform output -raw talosconfig > talosconfig"
  value       = module.kubernetes.talosconfig
  sensitive   = true
}

output "tailscale" {
  description = "The tailnet names of the nodes."
  value       = module.kubernetes.tailscale
}

output "tailscale_policy" {
  description = "The tags and grants that the Headscale policy needs. Add them yourself when manage_policy is false."
  value       = module.kubernetes.tailscale_policy
}

output "nodes" {
  value = module.kubernetes.nodes
}
