output "kubeconfig" {
  description = "Save it with: terraform output -raw kubeconfig > kubeconfig"
  value       = module.kubernetes.kubeconfig
  sensitive   = true
}

output "talosconfig" {
  description = "Save it with: terraform output -raw talosconfig > talosconfig"
  value       = module.kubernetes.talosconfig
  sensitive   = true
}

output "nodes" {
  value = module.kubernetes.nodes
}
