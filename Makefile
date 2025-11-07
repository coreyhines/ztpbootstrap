# Makefile for ZTP Bootstrap Service
# Provides common development tasks

.PHONY: help test lint format check install-deps clean

help: ## Show this help message
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

install-deps: ## Install development dependencies
	@echo "Installing development dependencies..."
	@command -v shellcheck >/dev/null 2>&1 || { echo "Installing shellcheck..."; \
		if command -v brew >/dev/null 2>&1; then brew install shellcheck; \
		elif command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y shellcheck; \
		elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y ShellCheck; \
		else echo "Please install shellcheck manually"; exit 1; fi; }
	@command -v yamllint >/dev/null 2>&1 || { echo "Installing yamllint..."; \
		if command -v brew >/dev/null 2>&1; then brew install yamllint; \
		elif command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y yamllint; \
		elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y yamllint; \
		else echo "Please install yamllint manually"; exit 1; fi; }
	@command -v yq >/dev/null 2>&1 || { echo "Installing yq..."; \
		if command -v brew >/dev/null 2>&1; then brew install yq; \
		elif command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y yq; \
		elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y yq; \
		else echo "Please install yq manually"; exit 1; fi; }
	@command -v bats >/dev/null 2>&1 || { echo "Installing bats..."; \
		if command -v brew >/dev/null 2>&1; then brew install bats-core; \
		elif command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y bats; \
		elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y bats; \
		else echo "Please install bats manually: https://github.com/bats-core/bats-core"; exit 1; fi; }
	@command -v black >/dev/null 2>&1 || { echo "Installing black (Python formatter)..."; \
		pip3 install --user black; }
	@echo "Dependencies installed!"

lint: ## Run linting checks
	@echo "Running shellcheck..."
	@shellcheck -S error *.sh || true
	@echo "Running yamllint..."
	@yamllint *.yaml *.yml config.yaml.template 2>/dev/null || echo "yamllint: No YAML files to check or yamllint not installed"

format: ## Format code
	@echo "Formatting Python code with black..."
	@black bootstrap.py 2>/dev/null || echo "black not installed, skipping Python formatting"
	@echo "Formatting complete. Note: Shell scripts should be formatted manually."

test: ## Run all tests
	@echo "Running unit tests..."
	@if command -v bats >/dev/null 2>&1; then \
		bats tests/unit/*.bats || echo "Some unit tests failed or bats not installed"; \
	else \
		echo "bats not installed, skipping unit tests"; \
	fi
	@echo "Running integration tests..."
	@if command -v bats >/dev/null 2>&1; then \
		bats tests/integration/*.bats || echo "Some integration tests failed or bats not installed"; \
	else \
		echo "bats not installed, skipping integration tests"; \
	fi

test-unit: ## Run unit tests only
	@if command -v bats >/dev/null 2>&1; then \
		bats tests/unit/*.bats; \
	else \
		echo "bats not installed"; exit 1; \
	fi

test-integration: ## Run integration tests only
	@if command -v bats >/dev/null 2>&1; then \
		bats tests/integration/*.bats; \
	else \
		echo "bats not installed"; exit 1; \
	fi

check: lint test ## Run linting and tests

validate-config: ## Validate config.yaml
	@if [ -f config.yaml ]; then \
		./validate-config.sh config.yaml; \
	else \
		echo "config.yaml not found"; exit 1; \
	fi

clean: ## Clean up test artifacts
	@echo "Cleaning up..."
	@rm -rf tests/tmp
	@rm -rf __pycache__
	@rm -rf .pytest_cache
	@find . -name "*.pyc" -delete
	@find . -name ".pytest_cache" -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "Cleanup complete"
