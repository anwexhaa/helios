terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state lives in an Azure Storage container so the cluster can be
  # destroyed and rebuilt from any machine. Create it once with
  # scripts/bootstrap-state.sh, then:
  #
  #   terraform init -backend-config=backend.hcl
  #
  # backend.hcl holds the storage account name and is not committed.
  backend "azurerm" {}
}

provider "azurerm" {
  features {
    key_vault {
      # This environment is rebuilt constantly. Soft-deleted vaults left
      # behind would block the next `make up` on a name collision.
      purge_soft_delete_on_destroy = true
    }
    resource_group {
      # `make down` must actually succeed. Without this, a resource created
      # outside Terraform (an AKS-managed load balancer, say) blocks destroy.
      prevent_deletion_if_contains_resources = false
    }
  }
}
