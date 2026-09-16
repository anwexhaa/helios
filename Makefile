.DEFAULT_GOAL := help
SHELL := /bin/bash

TF := terraform -chdir=infra

.PHONY: help preflight bootstrap init fmt validate plan up down creds namespaces deploy smoke check-rules monitoring grafana cost

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

namespaces: ## Create the three environment namespaces with quotas. Run once after make up.
	@kubectl apply -f k8s/namespaces.yaml
	@kubectl get namespace -l app.kubernetes.io/part-of=helios

deploy: ## Deploy the app to one environment: make deploy ENV=dev
	@kubectl apply -k k8s/overlays/$(ENV)
	@kubectl -n helios-$(ENV) rollout status deploy/orion-api --timeout=180s

smoke: ## Smoke test one environment via port-forward: make smoke ENV=dev
	@bash -c 'kubectl -n helios-$(ENV) port-forward svc/orion-api 18080:80 >/dev/null 2>&1 & pf=$$!; sleep 5; ./scripts/smoke.sh http://localhost:18080; rc=$$?; kill $$pf 2>/dev/null; exit $$rc'

check-rules: ## Validate the Prometheus rules with promtool. Needs Docker, not a cluster.
	@./scripts/check-rules.sh

monitoring: ## Install kube-prometheus-stack and apply the SLO rules and dashboard
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
	@helm repo update >/dev/null
	@helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \n	  --namespace monitoring --create-namespace \n	  --values k8s/monitoring/values-kube-prometheus-stack.yaml --wait
	@kubectl apply -f k8s/monitoring/prometheus-rules.yaml \n	  -f k8s/monitoring/podmonitor.yaml \n	  -f k8s/monitoring/grafana-dashboard.yaml

grafana: ## Port-forward Grafana to localhost:3000
	@kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

cost: ## Rough daily cost of what is currently running
	@echo "Node pool:       ~rs 85/day per Standard_B2s_v2 node"
	@echo "Log Analytics:   free below 5 GB ingested per month"
	@echo "ACR Basic:       ~rs 15/day"
	@echo "Load balancer:   ~rs 20/day while a Service of type LoadBalancer exists"
	@echo
	@echo "Nothing here bills while the environment is destroyed. Run 'make down'."
