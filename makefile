# ==============================================================================
# Project: SimpleInfrastructureStack
# Description: Makefile for managing the development and validation workflow.
# ==============================================================================

# Use bash for all commands
SHELL := /bin/bash

# Define colors for output
GREEN := \033[0;32m
YELLOW := \033[0;33m
NC := \033[0m

.PHONY: help install-hooks format lint check

help:
	@echo -e "$(GREEN)Available commands:$(NC)"
	@echo -e "  $(YELLOW)install-hooks$(NC)  - Installs the pre-commit git hooks into your local repository."
	@echo -e "  $(YELLOW)format$(NC)         - Manually formats all YAML and Markdown files in the repository."
	@echo -e "  $(YELLOW)lint$(NC)           - Manually runs all linting and formatting checks on all files."
	@echo -e "  $(YELLOW)check$(NC)          - Alias for 'lint'."


install-hooks:
	@echo -e "$(GREEN)--> Installing pre-commit hooks...$(NC)"
	@pre-commit install
	@echo -e "$(GREEN)Hooks installed successfully. They will now run automatically on every 'git commit'.$(NC)"


format:
	@echo -e "$(GREEN)--> Manually formatting all supported files...$(NC)"
	@pre-commit run prettier --all-files


lint check:
	@echo -e "$(GREEN)--> Running all checks on all files...$(NC)"
	@pre-commit run --all-files

# ===================================================================
# Infrastructure Validation Targets
# ===================================================================

.PHONY: check-policies
check-policies: ## Run OPA/Conftest policies against all compose files
	@echo "Running security policies against docker-compose files..."
	@command -v conftest >/dev/null 2>&1 || { echo "conftest not installed. Install: brew install conftest || snap install conftest"; exit 1; }
	@for f in $$(find . -name 'docker-compose.yml'); do \
		echo "Checking $$f..."; \
		conftest test -p policies/ "$$f" || exit 1; \
	done
	@echo "All policies passed."

.PHONY: check-images
check-images: ## Verify all Docker images are pinned
	@echo "Checking for unpinned Docker images..."
	@FAILED=0; \
	for f in $$(find . -name 'docker-compose.yml'); do \
		if grep -n 'image:.*:latest' "$$f" 2>/dev/null; then \
			echo "ERROR: Unpinned image in $$f"; \
			FAILED=1; \
		fi; \
	done; \
	if [ "$$FAILED" -eq "1" ]; then echo "FAILED: Found unpinned images"; exit 1; fi; \
	echo "All images are pinned."

.PHONY: check-env-examples
check-env-examples: ## Verify all stacks have .env.example files
	@echo "Checking for .env.example files..."
	@FAILED=0; \
	for dir in $$(find . -name 'docker-compose.yml' -exec dirname {} \;); do \
		if [ ! -f "$$dir/.env.example" ]; then \
			echo "WARNING: Missing .env.example in $$dir"; \
			FAILED=1; \
		fi; \
	done; \
	if [ "$$FAILED" -eq "1" ]; then echo "Some stacks missing .env.example"; exit 1; fi; \
	echo "All stacks have .env.example files."

.PHONY: security-audit
security-audit: check-policies check-images check-env-examples ## Run all security checks
	@echo "All security checks passed."

.PHONY: terraform-plan
terraform-plan: ## Show Terraform execution plan
	@cd terraform && terraform plan

.PHONY: terraform-apply
terraform-apply: ## Apply Terraform infrastructure changes
	@cd terraform && terraform apply -auto-approve
