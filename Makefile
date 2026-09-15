.DEFAULT_GOAL := help
SHELL := /bin/bash

ENV ?= dev
TF  := terraform -chdir=infra

.PHONY: help preflight init plan up down fmt validate namespaces

help: ## Show available targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-12s %s\n", $$1, $$2}'

preflight: ## Verify the local toolchain before touching Azure
	@./scripts/preflight.sh

init: ## Initialise Terraform and the remote state backend
	@echo "Not implemented until Phase 1." && exit 1

plan: ## Show what would change in Azure
	@echo "Not implemented until Phase 1." && exit 1

up: ## Provision the whole environment
	@echo "Not implemented until Phase 1." && exit 1

down: ## Destroy the whole environment. Run this at the end of every session.
	@echo "Not implemented until Phase 1." && exit 1

fmt: ## Format Terraform
	@echo "Not implemented until Phase 1." && exit 1

validate: ## Validate Terraform
	@echo "Not implemented until Phase 1." && exit 1

namespaces: ## Show the three environment namespaces
	@kubectl get namespace -l app.kubernetes.io/part-of=helios
