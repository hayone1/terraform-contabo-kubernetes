output "url" {
  description = "The address of Rancher."
  value       = local.rancher_url
}

output "bootstrap_password" {
  description = "The password of the local Rancher user \"admin\". Use it only when the Entra ID login does not work."
  value       = random_password.bootstrap.result
  sensitive   = true
}

output "rancher_client_id" {
  description = "The client ID of the app registration that people log in to."
  value       = azuread_application.rancher.client_id
}

output "rotator_client_id" {
  description = "The client ID of the app registration that the secret rotation job uses."
  value       = azuread_application.rotator.client_id
}

output "rotate_now_command" {
  description = "A command that creates a new client secret at once, for example after a leak."
  value       = "kubectl -n ${var.secret_rotation.namespace} create job rotate-now-$(date +%s) --from=cronjob/rancher-entra-auth-rotate --dry-run=client -o json | jq '.spec.template.spec.containers[0].env += [{\"name\": \"FORCE_ROTATION\", \"value\": \"true\"}]' | kubectl create -f -"
}
