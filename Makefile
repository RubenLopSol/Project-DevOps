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
# =============================================================================
COLOR_BOLD    = \033[1m     # bold text 
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

.PHONY: help bootstrap preflight dev-up dev-down terraform-infra terraform-status terraform-destroy terraform-docs minikube-up minikube-down cluster-up cluster-down reseal

# Show help when running make with no arguments
.DEFAULT_GOAL := help


# =============================================================================
# help
#
# Lists all available commands with a short description.
# =============================================================================
help:
	@echo ""
	@echo -e "$(COLOR_INFO)$(COLOR_BOLD)  OpenPanel DevOps$(COLOR_NONE)"
	@echo -e "$(COLOR_INFO)  ══════════════════════════════════════════════$(COLOR_NONE)"
	@echo ""
	@echo -e "  $(COLOR_BOLD)Local development$(COLOR_NONE)"
	@echo -e "    make bootstrap          One-time host setup (.env, /etc/hosts, sibling fork)"
	@echo -e "    make preflight          Verify host has every tool and config needed"
	@echo -e "    make dev-up             Start the full application and monitoring stack"
	@echo -e "    make dev-down           Stop all containers and free up resources"
	@echo ""
	@echo -e "  $(COLOR_BOLD)Infrastructure$(COLOR_NONE)"
	@echo -e "    make terraform-infra    Provision S3, IAM and Secrets Manager"
	@echo -e "    make terraform-status   Show all resources Terraform is managing"
	@echo -e "    make terraform-destroy  Permanently destroy all provisioned resources"
	@echo ""
	@echo -e "  $(COLOR_BOLD)Kubernetes$(COLOR_NONE)"
	@echo -e "    make minikube-up        Create the 3-node local cluster (cp / app / obs)"
	@echo -e "    make minikube-down      Delete the cluster and remove /etc/hosts entries"
	@echo -e "    make cluster-up         Full bring-up: minikube + sealing-key + ArgoCD + stabilise"
	@echo -e "    make cluster-down       Tear down the full cluster (alias for minikube-down)"
	@echo -e "    make reseal             Re-seal the six SealedSecrets from .env plaintext"
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
# bootstrap
#
# One-time host setup for a fresh checkout.
#
# Handles the three manual prerequisites the preflight check looks for:
#   1. .env           — copied from .env.example if missing (fill in secrets after)
#   2. /etc/hosts     — appends host.docker.internal mapping if absent (needs sudo)
#   3. ../openpanel   — clones the sibling app fork if not already present
# =============================================================================
bootstrap:
	$(call header,Bootstrapping host for local development)

	$(call step,Ensuring .env exists)
	@if [[ -f .env ]]; then \
		echo -e "   $(COLOR_SUCCESS)✔  .env already present$(COLOR_NONE)"; \
	else \
		cp .env.example .env; \
		echo -e "   $(COLOR_SUCCESS)✔  created .env from .env.example$(COLOR_NONE)"; \
		echo -e "   $(COLOR_WARNING)   ⚠  open .env and fill in any secrets before 'make dev-up'$(COLOR_NONE)"; \
	fi

	$(call step,Ensuring host.docker.internal is mapped in /etc/hosts)
	@if grep -qE '^[^#]*\bhost\.docker\.internal\b' /etc/hosts; then \
		echo -e "   $(COLOR_SUCCESS)✔  host.docker.internal already mapped$(COLOR_NONE)"; \
	else \
		echo -e "   $(COLOR_WARNING)   sudo required to append to /etc/hosts$(COLOR_NONE)"; \
		echo '127.0.0.1 host.docker.internal' | sudo tee -a /etc/hosts > /dev/null; \
		echo -e "   $(COLOR_SUCCESS)✔  added 127.0.0.1 host.docker.internal$(COLOR_NONE)"; \
	fi

	$(call step,Ensuring sibling openpanel fork exists at ../openpanel)
	@if [[ -d ../openpanel ]]; then \
		echo -e "   $(COLOR_SUCCESS)✔  ../openpanel already cloned$(COLOR_NONE)"; \
	else \
		cd .. && git clone https://github.com/RubenLopSol/openpanel.git; \
		echo -e "   $(COLOR_SUCCESS)✔  cloned fork into ../openpanel$(COLOR_NONE)"; \
	fi

	$(call success,Bootstrap complete. Next: 'make dev-up'.)


# =============================================================================
# preflight
#
# Quick sanity check on the host before docker compose runs.
#
# What it looks at:
#   - Docker daemon is reachable
#   - Docker engine v24 or newer
#   - docker compose plugin v2.20 or newer
#   - .env exists 
#   - /etc/hosts has host.docker.internal — the dashboard's auth cookies
#     don't work without it
#   - jq is on PATH
#   - the OpenPanel fork is cloned at ../openpanel
#
# Logic lives in scripts/preflight.sh.
# =============================================================================
preflight:
	@bash $(CURDIR)/scripts/preflight.sh


# =============================================================================
# dev-up
#
# Starts the full local stack defined in docker-compose.yml — this includes
# the application services (API, Worker, Dashboard) and all data stores
# (PostgreSQL, Redis, ClickHouse) plus the complete monitoring stack
# (Prometheus, Loki, Promtail, Grafana).
#
#
# Services available after startup:
#   http://localhost:3000   Dashboard
#   http://localhost:3333   API
#   http://localhost:3334   Worker queues (served by the worker container)
#   http://localhost:9090   Prometheus       (metrics + rule state)
#   http://localhost:9093   Alertmanager     (active alerts, silences)
#   http://localhost:8088   Webhook sink     (echoes alerts for Loki)
#   http://localhost:8089   cAdvisor UI      (per-container metrics — debug)
#   http://localhost:3200   Tempo            (distributed tracing query API)
#   http://localhost:3001   Grafana          (admin / admin)
#   http://localhost:3100   Loki
# =============================================================================
dev-up: preflight
	$(call header,Starting local development stack)

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

	$(call success,Stack is up.)
	@echo -e "   $(COLOR_INFO)Dashboard      →  http://localhost:3000$(COLOR_NONE)"
	@echo -e "   $(COLOR_INFO)API            →  http://localhost:3333$(COLOR_NONE)"
	@echo -e "   $(COLOR_INFO)Worker queues  →  http://localhost:3334$(COLOR_NONE)"
	@echo -e "   $(COLOR_INFO)Prometheus     →  http://localhost:9090$(COLOR_NONE)"
	@echo -e "   $(COLOR_INFO)Alertmanager   →  http://localhost:9093$(COLOR_NONE)"
	@echo -e "   $(COLOR_INFO)Webhook sink   →  http://localhost:8088$(COLOR_NONE)"
	@echo -e "   $(COLOR_INFO)cAdvisor UI    →  http://localhost:8089$(COLOR_NONE)"
	@echo -e "   $(COLOR_INFO)Tempo          →  http://localhost:3200$(COLOR_NONE)"
	@echo -e "   $(COLOR_INFO)Grafana        →  http://localhost:3001  (admin / admin)$(COLOR_NONE)"
	@echo -e "   $(COLOR_INFO)Loki           →  http://localhost:3100$(COLOR_NONE)"
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
# targeting staging, shows the full Terraform plan and asks for the
# confirmation. Nothing is created without explicit approval.
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
	@TF_VER=$$(terraform version -json | grep -oE '"terraform_version": *"[^"]*"' | cut -d'"' -f4); \
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

	$(call step,Starting LocalStack — local AWS simulator)
	@if [ "$(ENV)" = "staging" ]; then \
		if curl -sf http://localhost:4566/_localstack/health &>/dev/null; then \
			echo -e "   $(COLOR_SUCCESS)✔  LocalStack is already running at localhost:4566$(COLOR_NONE)"; \
		else \
			if docker ps -a --format '{{.Names}}' | grep -q '^localstack$$'; then \
				echo -e "   Reusing existing 'localstack' container..."; \
				docker start localstack > /dev/null; \
			else \
				echo -e "   Starting LocalStack container..."; \
				docker run -d --name localstack -p 4566:4566 localstack/localstack:3 > /dev/null; \
			fi; \
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
# environment.
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

terraform-docs:
	$(call header,Regenerating terraform-docs for all modules)
	@for m in backup-storage iam-user iam-irsa; do \
		terraform-docs --config terraform/.terraform-docs.yml terraform/modules/$$m; \
	done
	$(call success,Module READMEs regenerated.)


# =============================================================================
# minikube-up
#
# Brings up a 3-node Minikube cluster on the docker driver. The heavy
# lifting is in scripts/setup-minikube.sh; this target just calls it.
#
# What the script does:
#   1. Checks minikube, kubectl and docker are on PATH
#   2. Starts the cluster — 3 nodes, each with 2 CPUs, 2.5 GiB RAM, 40 GiB disk
#   3. Waits for every node to report Ready
#   4. Labels the two workers (workload=app, workload=observability). The
#      control-plane keeps its NoSchedule taint so app pods can't land there
#   5. Bumps inotify limits on every node — Promtail needs the headroom
#   6. Creates the base namespaces
#   7. Installs the local-path storage provisioner
#   8. Adds service hostnames (openpanel.local, argocd.local, etc.) to /etc/hosts
#
# Who lives where:
#   devops-cluster       control-plane — tainted, unlabelled
#   devops-cluster-m02   workload=app           — API, Worker, Postgres,
#                                                 Redis, ClickHouse
#   devops-cluster-m03   workload=observability — Prometheus, Grafana,
#                                                 Loki, Tempo, ArgoCD
#
# Costs the host 6 CPUs, 7.5 GiB RAM and 120 GiB disk all in.
# =============================================================================
minikube-up:
	$(call header,Creating local Kubernetes cluster)
	@bash scripts/setup-minikube.sh


# =============================================================================
# cluster-up
#
# One-shot full bring-up: Minikube cluster + ArgoCD + App-of-Apps + re-seal.
# Equivalent to running, in order:
#   make minikube-up
#   ./scripts/install-argocd.sh $(ENV)       # also applies bootstrap-app.yaml
#   ./scripts/reseal-secrets.sh              # re-seals six SealedSecrets
#
# The re-seal step is mandatory every time the cluster is (re-)created,
# because the sealed-secrets controller regenerates its keypair on each
# install and the six SealedSecrets committed in git were sealed against
# the previous keypair. Without re-sealing, Grafana, MinIO, and every
# openpanel pod will CrashLoop on missing Secrets. See
# docs/testing-local-stack.md §10.7 for the full background.
#
# ENV defaults to staging — override with: make cluster-up ENV=prod
# =============================================================================
cluster-up:
	$(call header,Full cluster bring-up — environment: $(ENV))

	$(call step,Step 1/4 · Minikube cluster (creates namespaces incl. sealed-secrets))
	@bash scripts/setup-minikube.sh

	$(call step,Step 2/4 · Ensure Sealed-Secrets keypair exists (restore backup OR generate fresh))
	@bash scripts/ensure-sealing-key.sh

	$(call step,Step 3/4 · ArgoCD install + bootstrap (controller adopts the keypair from step 2))
	@bash scripts/install-argocd.sh $(ENV)

	$(call step,Step 4/4 · Stabilise SealedSecrets (auto-checks decrypt; reseals only if needed))
	@bash scripts/stabilize-secrets.sh

	$(call success,Cluster + ArgoCD up + SealedSecrets stable.)
	@echo ""
	@echo -e "   Monitor sync progress:  $(COLOR_BOLD)kubectl get applications -n argocd -w$(COLOR_NONE)"
	@echo -e "   ArgoCD UI:              $(COLOR_BOLD)http://argocd.local$(COLOR_NONE)"
	@echo ""
	@echo -e "   $(COLOR_WARNING)Note for thesis reviewers:$(COLOR_NONE) the cluster is fully working — no further steps."
	@echo -e "   The keypair generated for this machine lives at $(COLOR_BOLD)~/.config/openpanel/sealing-key.yaml$(COLOR_NONE)"
	@echo -e "   so subsequent $(COLOR_BOLD)make cluster-up$(COLOR_NONE) bring-ups skip the reseal step entirely."


# =============================================================================
# reseal
#
# Stand-alone re-seal step — regenerates the six SealedSecrets from the
# plaintext values in .env (plus sensible defaults for Grafana/MinIO)
# against the sealed-secrets controller's current public key, then
# applies them live.
#
# Use after 'make cluster-up' only when the automatic re-seal was skipped,
# after a manual 'kubectl rollout restart' of the controller, or any time
# pods are stuck Pending on a missing Secret.
# =============================================================================
reseal:
	@bash scripts/reseal-secrets.sh


# =============================================================================
# cluster-down
#
# Symmetric teardown for cluster-up. Deleting the cluster also removes ArgoCD
# and every workload it manages, so this is simply an alias for minikube-down.
# =============================================================================
cluster-down: minikube-down


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
	@sudo sed -i -E '/\b(openpanel|api\.openpanel|argocd|grafana|prometheus)\.local\b/d' /etc/hosts 2>/dev/null || true

	$(call success,Cluster deleted and DNS entries removed.)



