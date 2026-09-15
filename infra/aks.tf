# ---------------------------------------------------------------------------
# AKS cluster
#
# One autoscaling node pool rather than a separate system and user pool. Two
# pools means two nodes running at all times, roughly doubling the daily cost
# for a build that has one workload on it. See decision D7.
# ---------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = local.name
  kubernetes_version  = var.kubernetes_version

  # Free tier has no control plane SLA, which is the honest choice here: the
  # 99.5% target in docs/slo.md covers the service, not Azure's control plane.
  sku_tier = "Free"

  # Workload identity: pods exchange a projected service account token for an
  # Azure token. No client secret is ever stored in the cluster.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                 = "system"
    vm_size              = var.node_size
    vnet_subnet_id       = azurerm_subnet.aks.id
    auto_scaling_enabled = true
    min_count            = var.node_min_count
    max_count            = var.node_max_count
    os_disk_size_gb      = 64

    # With Azure CNI each pod takes a subnet address. node_max_count *
    # (max_pods + 1) must fit inside aks_subnet_cidr.
    max_pods = 50

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "calico"
    load_balancer_sku = "standard"
    service_cidr      = var.service_cidr
    dns_service_ip    = var.dns_service_ip
  }

  # Container Insights. Node, pod and container telemetry lands in the
  # workspace Phase 3 writes KQL against.
  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  }

  # Mounts Key Vault secrets as files via the CSI driver, so nothing has to be
  # copied into a Kubernetes Secret first.
  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [
      # The autoscaler owns this number once the cluster is running. Without
      # this, every plan wants to reset it to the floor.
      default_node_pool[0].node_count,
    ]
  }
}

# ---------------------------------------------------------------------------
# Let the cluster pull from the registry
#
# The kubelet identity gets AcrPull, so deployments need no imagePullSecret
# and no registry password exists anywhere.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# ---------------------------------------------------------------------------
# Let the cluster read Key Vault
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "aks_kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].object_id
}
