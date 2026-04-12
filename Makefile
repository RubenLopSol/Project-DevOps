# =============================================================================
# OpenPanel DevOps — Makefile
#
# This Makefile automates local development and infrastructure provisioning
# for the OpenPanel platform.
#
# Usage:
#   make                       show available commands
#
# Local development (Docker Compose):
#   make dev-up                start the full application and monitoring stack
#   make dev-down              stop all containers and free resources
#   make dev-logs              follow live logs from all containers
#   make dev-status            show the health of every running container
#
# Infrastructure (Terraform):
#   make terraform-infra       provision S3, IAM and Secrets Manager
#   make terraform-status      show what resources Terraform is managing
#   make terraform-destroy     tear down all provisioned resources
#
# Kubernetes (Minikube):
#   make minikube-up           create the 3-node local cluster and configure DNS
#   make minikube-down         delete the cluster and remove DNS entries
#
# To target a specific Terraform environment:
#   make terraform-infra ENV=prod
#
# =============================================================================

SHELL := /bin/bash

# Make sure binaries installed in the user's local bin directory are found.
# This covers tools like terraform or aws CLI installed without sudo.
export PATH := $(shell echo $$HOME)/.local/bin:$(PATH)

# Terraform uses the Go runtime which defaults to IPv6 on some systems.
# This forces IPv4 to avoid connection timeouts when downloading providers.
export GODEBUG := netdns=go preferIPv4=1

# The target environment. Defaults to staging — override with ENV=prod.
ENV ?= staging

# Minikube cluster profile name — must match the CLUSTER_NAME in setup-minikube.sh.
PROFILE ?= devops-cluster

# Minimum Terraform version required to run this project.
# Must match the required_version in terraform/environments/*/versions.tf.
TF_MIN_MAJOR = 1
TF_MIN_MINOR = 5


# =============================================================================
# Terminal colors
#
# Used to make output easier to read at a glance.
# Each variable is named after its purpose, not the color itself.
# =============================================================================
COLOR_BOLD    = \033[1m     # bold text — no color change, just weight
COLOR_NONE    = \033[0m     # reset — clears all color and formatting
COLOR_ERROR   = \033[0;31m  # red — errors and destructive actions
COLOR_SUCCESS = \033[0;32m  # green — success messages and confirmations
COLOR_WARNING = \033[1;33m  # yellow — warnings, aborts, and cautions
COLOR_INFO    = \033[0;36m  # cyan — headers, steps, and informational output


# =============================================================================
# Output helpers
#
# Consistent formatting for every message printed during a make run.
#   header  — top-level section title
#   step    — individual step within a section
#   success — positive outcome at the end of a target
#   fail    — error message before exiting
# =============================================================================
header  = @echo -e "\n$(COLOR_INFO)$(COLOR_BOLD)▶  $(1)$(COLOR_NONE)"
step    = @echo -e "$(COLOR_WARNING)   →  $(1)$(COLOR_NONE)"
success = @echo -e "$(COLOR_SUCCESS)$(COLOR_BOLD)   ✔  $(1)$(COLOR_NONE)\n"
fail    = @echo -e "$(COLOR_ERROR)$(COLOR_BOLD)   ✖  $(1)$(COLOR_NONE)" >&2


# =============================================================================

.PHONY: help dev-up dev-down dev-logs dev-status terraform-infra terraform-status terraform-destroy minikube-up minikube-down

# Show help when running make with no arguments
.DEFAULT_GOAL := help


# =============================================================================
# help
#
# Lists all available commands with a short description.
# This is what you see when you run `make` on its own.
# =============================================================================
help:
	@echo ""
	@echo -e "$(COLOR_INFO)$(COLOR_BOLD)  OpenPanel DevOps$(COLOR_NONE)"
	@echo -e "$(COLOR_INFO)  ══════════════════════════════════════════════$(COLOR_NONE)"
	@echo ""
	@echo -e "  $(COLOR_BOLD)Local development$(COLOR_NONE)"
	@echo -e "    make dev-up             Start the full application and monitoring stack"
	@echo -e "    make dev-down           Stop all containers and free up resources"
	@echo -e "    make dev-logs           Follow live logs from all running containers"
	@echo -e "    make dev-status         Show the health of every running container"
	@echo ""
	@echo -e "  $(COLOR_BOLD)Infrastructure$(COLOR_NONE)"
	@echo -e "    make terraform-infra    Provision S3, IAM and Secrets Manager"
	@echo -e "    make terraform-status   Show all resources Terraform is managing"
	@echo -e "    make terraform-destroy  Permanently destroy all provisioned resources"
	@echo ""
	@echo -e "  $(COLOR_BOLD)Kubernetes$(COLOR_NONE)"
	@echo -e "    make minikube-up        Create the 3-node local cluster and configure DNS"
	@echo -e "    make minikube-down      Delete the cluster and remove /etc/hosts entries"
	@echo ""
	@echo -e "  $(COLOR_WARNING)Terraform environment options:$(COLOR_NONE)"
	@echo -e "    ENV=staging  (default) — uses LocalStack running in Docker"
	@echo -e "    ENV=prod               — uses real AWS, requires credentials"
	@echo ""
	@echo -e "  $(COLOR_WARNING)Examples:$(COLOR_NONE)"
	@echo -e "    make dev-up"
	@echo -e "    make terraform-infra ENV=staging"
	@echo ""


# =============================================================================
# dev-up
#
# Starts the full local stack defined in docker-compose.yml — this includes
# the application services (API, Worker, Dashboard) and all data stores
# (PostgreSQL, Redis, ClickHouse) plus the complete monitoring stack
# (Prometheus, Loki, Promtail, Grafana).
#
# On first run, Docker builds images from source which takes ~10 minutes.
# Subsequent runs reuse the build cache and start in ~1-2 minutes.
#
# Before running:
#   cp .env.example .env    — create your local environment file
#
# Services available after startup:
#   http://localhost:3000   Dashboard
#   http://localhost:3333   API
#   http://localhost:3334   BullBoard (queue monitor)
#   http://localhost:9090   Prometheus
#   http://localhost:3001   Grafana  (admin / admin)
#   http://localhost:3100   Loki
# =============================================================================
dev-up:
	$(call header,Starting local development stack)

	$(call step,Checking that Docker is running)
	@if ! docker info &>/dev/null; then \
		$(call fail,Docker is not running — please start Docker and try again); \
		exit 1; \
	fi
	@echo -e "   $(COLOR_SUCCESS)✔  Docker is running$(COLOR_NONE)"

	$(call step,Checking that .env file exists)
	@if [ ! -f ".env" ]; then \
		$(call fail,.env file not found); \
		echo -e "     Copy the example file and fill in your values:" >&2; \
		echo -e "     cp .env.example .env" >&2; \
		exit 1; \
	fi
	@echo -e "   $(COLOR_SUCCESS)✔  .env file found$(COLOR_NONE)"

	$(call step,Building images and starting all containers)
	@echo ""
	docker compose up --build -d
	@echo ""

	$(call step,Waiting for the API to become healthy)
	@for i in $$(seq 1 20); do \
		if curl -sf http://localhost:3333/healthcheck &>/dev/null; then \
			echo -e "   $(COLOR_SUCCESS)✔  API is healthy at http://localhost:3333$(COLOR_NONE)"; \
			break; \
		fi; \
		echo -e "   Attempt $$i/20 — waiting for API to start..."; \
		sleep 5; \
	done

	$(call success,Stack is up. Run 'make dev-status' to see all services.)
	@echo -e "   $(COLOR_INFO)Dashboard   →  http://localhost:3000$(COLOR_NONE)"
	@echo -e "   $(COLOR_INFO)API         →  http://localhost:3333$(COLOR_NONE)"
	@echo -e "   $(COLOR_INFO)BullBoard   →  http://localhost:3334$(COLOR_NONE)"
	@echo -e "   $(COLOR_INFO)Prometheus  →  http://localhost:9090$(COLOR_NONE)"
	@echo -e "   $(COLOR_INFO)Grafana     →  http://localhost:3001  (admin / admin)$(COLOR_NONE)"
	@echo -e "   $(COLOR_INFO)Loki        →  http://localhost:3100$(COLOR_NONE)"
	@echo ""


# =============================================================================
# dev-down
#
# Stops all containers, removes the network, and deletes all volumes created
# by docker compose. This performs a full reset — all database data is wiped.
# =============================================================================
dev-down:
	$(call header,Stopping local development stack)

	$(call step,Stopping and removing all containers and volumes)
	docker compose down -v

	$(call success,All containers stopped and volumes removed.)


# =============================================================================
# terraform-infra
#
# Provisions all cloud infrastructure from scratch. Before creating anything,
# it checks that the required tools are available, starts LocalStack when
# targeting staging, shows you the full Terraform plan and asks for your
# confirmation. Nothing is created until you explicitly say yes.
#
# Steps:
#   1. Check Terraform is installed
#   2. Check Docker is installed
#   3. Start LocalStack if it is not already running (staging only)
#   4. Initialise Terraform in the target environment
#   5. Generate and display the execution plan
#   6. Ask for confirmation
#   7. Apply the plan
# =============================================================================
terraform-infra:
	$(call header,Provisioning infrastructure — environment: $(ENV))

	$(call step,Checking that Terraform is installed and meets the minimum version)
	@if ! command -v terraform &>/dev/null; then \
		$(call fail,Terraform is not installed); \
		echo -e "     Get it from: https://developer.hashicorp.com/terraform/install" >&2; \
		exit 1; \
	fi
	@TF_VER=$$(terraform version -json | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4); \
	TF_MAJOR=$$(echo "$$TF_VER" | cut -d. -f1); \
	TF_MINOR=$$(echo "$$TF_VER" | cut -d. -f2); \
	if [[ "$$TF_MAJOR" -lt $(TF_MIN_MAJOR) ]] || { [[ "$$TF_MAJOR" -eq $(TF_MIN_MAJOR) ]] && [[ "$$TF_MINOR" -lt $(TF_MIN_MINOR) ]]; }; then \
		$(call fail,Terraform v$$TF_VER is too old — v$(TF_MIN_MAJOR).$(TF_MIN_MINOR).0 or newer is required); \
		echo -e "     Get the latest from: https://developer.hashicorp.com/terraform/install" >&2; \
		exit 1; \
	fi
	@echo -e "   $(COLOR_SUCCESS)✔  $$(terraform version | head -1)$(COLOR_NONE)"

	$(call step,Checking that Docker is installed)
	@if ! command -v docker &>/dev/null; then \
		$(call fail,Docker is not installed); \
		echo -e "     Get it from: https://docs.docker.com/get-docker/" >&2; \
		exit 1; \
	fi
	@echo -e "   $(COLOR_SUCCESS)✔  $$(docker --version)$(COLOR_NONE)"

	$(call step,Starting LocalStack — your local AWS simulator)
	@if [ "$(ENV)" = "staging" ]; then \
		if curl -sf http://localhost:4566/_localstack/health &>/dev/null; then \
			echo -e "   $(COLOR_SUCCESS)✔  LocalStack is already running at localhost:4566$(COLOR_NONE)"; \
		else \
			echo -e "   Starting LocalStack container..."; \
			docker run -d --name localstack -p 4566:4566 localstack/localstack:3 > /dev/null; \
			echo -e "   Waiting for LocalStack to become healthy..."; \
			for i in $$(seq 1 15); do \
				if curl -sf http://localhost:4566/_localstack/health &>/dev/null; then \
					echo -e "   $(COLOR_SUCCESS)✔  LocalStack is ready$(COLOR_NONE)"; \
					break; \
				fi; \
				sleep 2; \
			done; \
		fi; \
	else \
		echo -e "   $(COLOR_INFO)Skipped — prod targets real AWS$(COLOR_NONE)"; \
	fi

	$(call step,Initialising Terraform — downloading required providers)
	@cd terraform/environments/$(ENV) && terraform init -input=false

	$(call step,Generating execution plan — showing what will be created)
	@echo ""
	@cd terraform/environments/$(ENV) && terraform plan -input=false
	@echo ""

	@printf "$(COLOR_INFO)$(COLOR_BOLD)   Apply this plan and create the resources? [y/N]: $(COLOR_NONE)" && read confirm && \
		[[ "$${confirm}" == "y" ]] || [[ "$${confirm}" == "Y" ]] || \
		{ echo -e "\n$(COLOR_WARNING)   Aborted — no resources were created$(COLOR_NONE)\n"; exit 1; }

	$(call step,Applying plan — creating resources now)
	@cd terraform/environments/$(ENV) && terraform apply -input=false -auto-approve

	$(call success,All resources created. Run 'make terraform-status ENV=$(ENV)' to verify.)


# =============================================================================
# terraform-status
#
# Lists every resource that Terraform is currently tracking in its state file.
# Use this after provisioning to confirm everything was created, or any time
# you want a quick overview of what exists in a given environment.
# =============================================================================
terraform-status:
	$(call header,Terraform resource status — environment: $(ENV))

	@if [ ! -f "terraform/environments/$(ENV)/terraform.tfstate" ]; then \
		$(call fail,No state file found for environment: $(ENV)); \
		echo -e "     Run 'make terraform-infra ENV=$(ENV)' first to provision resources." >&2; \
		exit 1; \
	fi

	$(call step,Resources currently managed by Terraform)
	@echo ""
	@cd terraform/environments/$(ENV) && terraform state list
	@echo ""

	$(call success,Status check complete.)


# =============================================================================
# terraform-destroy
#
# Permanently destroys all resources Terraform manages in the target
# environment. This cannot be undone. You will be asked to confirm
# before anything is deleted.
# =============================================================================
terraform-destroy:
	$(call header,Destroying infrastructure — environment: $(ENV))

	@echo -e "   $(COLOR_WARNING)This will permanently delete all resources in $(COLOR_BOLD)$(ENV)$(COLOR_NONE)$(COLOR_WARNING).$(COLOR_NONE)"
	@echo -e "   $(COLOR_WARNING)This action cannot be undone.$(COLOR_NONE)"
	@echo ""

	@printf "$(COLOR_ERROR)$(COLOR_BOLD)   Are you sure you want to continue? [y/N]: $(COLOR_NONE)" && read confirm && \
		[[ "$${confirm}" == "y" ]] || [[ "$${confirm}" == "Y" ]] || \
		{ echo -e "\n$(COLOR_WARNING)   Aborted — nothing was destroyed$(COLOR_NONE)\n"; exit 1; }

	$(call step,Destroying all resources)
	@cd terraform/environments/$(ENV) && terraform destroy -auto-approve

	$(call success,All resources have been destroyed.)


# =============================================================================
# minikube-up
#
# Creates a 3-node local Kubernetes cluster using the Docker driver and
# bootstraps everything needed to deploy the full OpenPanel stack:
#
#   1. Checks that minikube, kubectl and docker are installed
#   2. Starts the cluster (3 nodes, 4 CPUs / 4 GiB / 40 GiB each)
#   3. Waits for all nodes to be Ready
#   4. Labels each node by workload type (app / observability)
#   5. Raises inotify limits on all nodes (required for Promtail)
#   6. Creates the base Kubernetes namespaces
#   7. Installs the local-path storage provisioner
#   8. Adds service hostnames to /etc/hosts
#
# Node layout:
#   devops-cluster       control-plane  — Kubernetes internals only
#   devops-cluster-m02   app node       — API, Worker, PostgreSQL, Redis, ClickHouse
#   devops-cluster-m03   observability  — Prometheus, Grafana, Loki, Tempo
#
# Resource footprint: 12 CPUs / 12 GiB RAM / 120 GiB disk total
# =============================================================================
minikube-up:
	$(call header,Creating local Kubernetes cluster)
	@bash scripts/setup-minikube.sh


# =============================================================================
# minikube-down
#
# Stops and permanently deletes the Minikube cluster, then removes the
# service hostname entries that were added to /etc/hosts by minikube-up.
# =============================================================================
minikube-down:
	$(call header,Tearing down local Kubernetes cluster)

	$(call step,Stopping cluster)
	@minikube stop -p $(PROFILE) 2>/dev/null || true

	$(call step,Deleting cluster)
	minikube delete -p $(PROFILE)

	$(call step,Removing /etc/hosts entries)
	@sudo sed -i '/openpanel\.local/d' /etc/hosts 2>/dev/null || true

	$(call success,Cluster deleted and DNS entries removed.)



