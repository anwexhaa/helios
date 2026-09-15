# infra

Terraform describing the entire Azure environment: resource group, virtual network, AKS
cluster, container registry, Log Analytics workspace and Key Vault.

Lands in Phase 1. Nothing here is applied by hand — `make up` and `make down` are the only
entry points, and remote state lives in an Azure Storage container so the cluster can be
destroyed and rebuilt from any machine.
