.DEFAULT_GOAL := help
SHELL := /bin/bash

TF := terraform -chdir=infra

.PHONY: help preflight bootstrap init fmt validate plan up down creds namespaces cost

help: ## Show available targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-12s %s\n", $$1, $$2}'

preflight: ## Verify the local toolchain and Azure sign-in
	@./scripts/preflight.sh

bootstrap: ## Create the storage account that holds Terraform state. Run once per subscription.
	@./scripts/bootstrap-state.sh

init: ## Initialise Terraform against the remote state backend
	@test -f infra/backend.hcl || { \
		echo "infra/backend.hcl is missing. Run 'make bootstrap' first."; exit 1; }
	@$(TF) init -backend-config=backend.hcl

fmt: ## Rewrite Terraform files into canonical format
	@$(TF) fmt -recursive

validate: ## Check the configuration is syntactically valid and internally consistent
	@$(TF) validate

plan: ## Show what would change in Azure, without changing it
	@$(TF) plan

up: ## Provision the environment. Shows the plan and asks before creating anything billable.
	@$(TF) apply
	@echo
	@echo "Cluster is up. Fetch credentials with:"
	@$(TF) output -raw get_credentials
	@echo

down: ## Destroy the environment. Run this at the end of every session.
	@$(TF) destroy

creds: ## Write this cluster into your kubeconfig
	@eval "$$($(TF) output -raw get_credentials)"

namespaces: ## Show the three environment namespaces
	@kubectl get namespace -l app.kubernetes.io/part-of=helios

cost: ## Rough daily cost of what is currently running
	@echo "Node pool:       ~rs 75/day per Standard_B2s node"
	@echo "Log Analytics:   free below 5 GB ingested per month"
	@echo "ACR Basic:       ~rs 15/day"
	@echo "Load balancer:   ~rs 20/day while a Service of type LoadBalancer exists"
	@echo
	@echo "Nothing here bills while the environment is destroyed. Run 'make down'."
