# Thin wrapper over scripts/. Everything here is also runnable directly, and the PowerShell
# equivalents (scripts/*.ps1) are first-class - use those on Windows without a Make install.
#
#   make deploy ARCHITECTURE=aks-private-vnet-integration RG=rg-aks-prod
#   make destroy ARCHITECTURE=aks-private-vnet-integration RG=rg-aks-prod

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

ARCHITECTURE   ?= aks-public
RG       ?=
LOCATION ?= westus3
PARAMS   := $(wildcard infra/params/*.bicepparam)
# A tier is any top-level object carrying a features block. Selecting them structurally means
# adding a schema note or other documentation key to that file does not break the build.
TIERS    := $(shell jq -r 'to_entries[] | select(.value|type=="object") | select(.value|has("features")) | .key' infra/params/cost-tiers.json 2>/dev/null)
# An empty TIERS would skip every parameter build and still report OK, so it is a hard error.
ifeq ($(strip $(TIERS)),)
$(error Could not read cost tiers from infra/params/cost-tiers.json. Is jq installed? The scripts require it too.)
endif

# Fails fast with a usable message instead of passing an empty -g through to az.
define need_rg
	@if [ -z "$(RG)" ]; then echo "RG is required, e.g. make $@ RG=rg-aks-prod ARCHITECTURE=$(ARCHITECTURE)"; exit 2; fi
endef

.PHONY: help
help: ## Show this help
	@echo "aks-architectures"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables: ARCHITECTURE=$(ARCHITECTURE)  RG=$(RG)  LOCATION=$(LOCATION)"
	@echo "Architectures:   $(notdir $(basename $(PARAMS)))"

.PHONY: wizard
wizard: ## Guided interview: choose a cluster shape, understand each trade-off, then deploy it
	@./scripts/wizard.sh $(if $(RG),-g $(RG),)

.PHONY: build
build: ## Compile every template and parameter file, at every cost tier
	@for f in $$(find infra -name '*.bicep' | sort); do \
		echo "  build $$f"; az bicep build --file "$$f" --stdout > /dev/null; \
	done
	@for t in $(TIERS); do \
		for f in $(PARAMS); do \
			echo "  params [$$t] $$f"; AKS_COST_TIER=$$t az bicep build-params --file "$$f" --stdout > /dev/null; \
		done; \
	done
	@echo "OK"

.PHONY: lint
lint: ## Shell, PowerShell and GitOps linting
	@for f in scripts/*.sh scripts/lib/*.sh; do bash -n "$$f"; done
	@command -v shellcheck > /dev/null && shellcheck --severity=warning scripts/*.sh scripts/lib/*.sh || echo "  shellcheck not installed, skipped"
	@command -v pwsh > /dev/null && pwsh -NoProfile -Command '$$f=$$false; Get-ChildItem scripts -Recurse -Include *.ps1,*.psm1 | ForEach-Object { $$e=$$null; [System.Management.Automation.Language.Parser]::ParseFile($$_.FullName,[ref]$$null,[ref]$$e) | Out-Null; if ($$e) { $$f=$$true; Write-Host "  $$($$_.Name): $$($$e[0].Message)" } }; if ($$f) { exit 1 }' || echo "  pwsh not installed, skipped"
	@python scripts/validate-gitops.py clusters
	@echo "OK"

.PHONY: validate
validate: build lint ## Everything CI runs offline

.PHONY: preflight
preflight: ## Run the network gate standalone
	$(call need_rg)
	@./scripts/preflight.sh --architecture $(ARCHITECTURE) -g $(RG) -l $(LOCATION)

.PHONY: cost
cost: ## Estimated monthly cost of an architecture. Deploys nothing, needs no Azure login.
	@source scripts/lib/common.sh; \
	  show_cost_estimate "$$(resolve_bicepparam infra/params/$(ARCHITECTURE).bicepparam)" \
	                     "$(ARCHITECTURE)" "$${AKS_COST_TIER:-lean}"

.PHONY: preview
preview: ## what-if, changes nothing
	$(call need_rg)
	@./scripts/deploy.sh --architecture $(ARCHITECTURE) -g $(RG) -l $(LOCATION) --preview

.PHONY: deploy
deploy: ## Pre-flight, then deploy
	$(call need_rg)
	@./scripts/deploy.sh --architecture $(ARCHITECTURE) -g $(RG) -l $(LOCATION)

.PHONY: diagnose
diagnose: ## Post-mortem for a failed deployment
	$(call need_rg)
	@./scripts/diagnose.sh -g $(RG)

.PHONY: verify-policy
verify-policy: ## Prove the assigned Deny rules are actually enforced, by attempting a public LoadBalancer
	$(call need_rg)
	@if [ -z "$(CLUSTER)" ]; then echo "CLUSTER is required, e.g. make verify-policy RG=$(RG) CLUSTER=aks-contoso-prod-wus3-01"; exit 2; fi
	@./scripts/verify-policy.sh -g $(RG) -n $(CLUSTER)

.PHONY: pause
pause: ## Deallocate the Azure Firewall and stop the clusters, keeping every resource
	$(call need_rg)
	@./scripts/pause.sh -g $(RG)

.PHONY: resume
resume: ## Allocate the firewall again, fix the UDR next hop, restart the clusters
	$(call need_rg)
	@./scripts/pause.sh -g $(RG) --resume

.PHONY: destroy
destroy: ## Remove everything, including role assignments, DNS links and policy definitions
	$(call need_rg)
	@./scripts/destroy.sh --architecture $(ARCHITECTURE) -g $(RG)

.PHONY: clean
clean: ## Delete generated local artefacts
	@rm -f preflight-*.json diagnose-*.json main.json
	@echo "OK"
