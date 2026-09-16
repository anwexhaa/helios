data "azurerm_client_config" "current" {}

locals {
  name = "${var.project}-${var.environment}"

  # Derived from the subscription id, not random. With a random suffix every
  # rebuild produced a new registry name, so the image reference in
  # k8s/base/kustomization.yaml went stale on every `make up` and had to be
  # edited by hand. A hash is still globally unique in practice and stays the
  # same across rebuilds of the same subscription.
  #
  # Trade-off: Key Vault now reuses its name, so a soft-deleted vault from the
  # last teardown must be purged first. purge_soft_delete_on_destroy in
  # versions.tf does that; if a destroy is interrupted before the purge, the
  # next apply fails on a name collision until the vault is purged by hand.
  suffix = substr(sha1(data.azurerm_client_config.current.subscription_id), 0, 6)

  # Container registry and Key Vault names are globally unique across all of
  # Azure, so both carry the suffix. ACR allows alphanumerics only, which a
  # hex digest satisfies.
  acr_name = "${var.project}acr${local.suffix}"
  kv_name  = "${var.project}-kv-${local.suffix}"

  tags = merge({
    project    = var.project
    managed_by = "terraform"
    repo       = "helios"
  }, var.tags)
}

# ---------------------------------------------------------------------------
# Resource group
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.aks_subnet_cidr]
}

# ---------------------------------------------------------------------------
# Container registry
# ---------------------------------------------------------------------------

resource "azurerm_container_registry" "this" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"

  # The cluster pulls with its kubelet identity (see aks.tf), so the admin
  # account stays off. An enabled admin account is a shared password.
  admin_enabled = false

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Log Analytics — Container Insights writes here, and Phase 3 queries it
# ---------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Key Vault — for the few values that genuinely must be secret
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "this" {
  name                = local.kv_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Azure RBAC rather than vault access policies: one authorisation model
  # across the whole subscription instead of two.
  rbac_authorization_enabled = true

  # This vault is destroyed and recreated constantly. Purge protection would
  # make the name unusable for 90 days after every `make down`.
  purge_protection_enabled   = false
  soft_delete_retention_days = 7

  tags = local.tags
}
