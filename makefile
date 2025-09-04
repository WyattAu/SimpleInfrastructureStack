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