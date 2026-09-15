output "resource_group" {
  description = "Resource group holding everything Terraform created."
  value       = azurerm_resource_group.this.name
}

output "cluster_name" {
  description = "AKS cluster name. Fetch credentials with the get_credentials command below."
  value       = azurerm_kubernetes_cluster.this.name
}

output "get_credentials" {
  description = "Ready-to-run command that writes this cluster into your kubeconfig."
  value = join(" ", [
    "az aks get-credentials",
    "--resource-group ${azurerm_resource_group.this.name}",
    "--name ${azurerm_kubernetes_cluster.this.name}",
    "--overwrite-existing",
  ])
}

output "acr_login_server" {
  description = "Registry hostname. Image tags are prefixed with this."
  value       = azurerm_container_registry.this.login_server
}

output "acr_name" {
  description = "Registry name, for `az acr login --name`."
  value       = azurerm_container_registry.this.name
}

output "log_analytics_workspace_id" {
  description = "Workspace resource ID, used by Phase 3 alert rules."
  value       = azurerm_log_analytics_workspace.this.id
}

output "key_vault_name" {
  description = "Key Vault name."
  value       = azurerm_key_vault.this.name
}

output "oidc_issuer_url" {
  description = "Cluster OIDC issuer. Federated identity credentials reference this."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kubelet_identity_object_id" {
  description = "Identity the nodes run as. Holds AcrPull on the registry."
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}
