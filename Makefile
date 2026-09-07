# =============================================================================
# Dockerwarts N°1 — operator entry point.
#
# Nominal sequence on a fresh workstation (CDC §13, Definition of Done):
#
#   cp .env.example .env
#   make vms provision secrets certs build deploy smoke chaos dr-drill
#
# Everything below is a thin, documented wrapper around scripts/ and ansible/:
# no logic lives in this file beyond ordering and guard rails.
# =============================================================================

# `command -v` is resolved by make at parse time: this picks up a modern bash
# from PATH (Homebrew on macOS, /usr/bin on Linux) rather than the 3.2 that
# ships with macOS. SHELL must be a plain path — `/usr/bin/env bash` is not one.
SHELL := $(shell command -v bash)
.SHELLFLAGS := -Eeuo pipefail -c
.DEFAULT_GOAL := help
.ONESHELL:

ROOT      := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ENV_FILE  := $(ROOT)/.env
ANSIBLE   := $(ROOT)/ansible
STACKS    := $(ROOT)/stacks
SCRIPTS   := $(ROOT)/scripts
TESTS     := $(ROOT)/tests
REPORTS   := $(ROOT)/reports

# Stacks are deployed in dependency order: data must be healthy before apps,
# which must exist before monitoring can scrape them.
STACK_ORDER := edge data apps monitoring backup

# Home-made images (CDC §10.2), built by `make build` and pushed to $(REGISTRY).
OWN_IMAGES := cassandra alert2glpi backup-runner demo-producer

export DOCKER_CLI_HINTS := false

# --- .env handling -----------------------------------------------------------
# Most targets need the variables; a few (help, lint) must work without a .env
# so that the CI can run them on a bare checkout.
ifneq (,$(wildcard $(ENV_FILE)))
include $(ENV_FILE)
export
endif

define require_env
	@if [ ! -f "$(ENV_FILE)" ]; then \
	  echo "ERROR: $(ENV_FILE) is missing. Run: cp .env.example .env"; exit 1; \
	fi
endef

# =============================================================================
help: ## Show this help
	@echo "Dockerwarts N°1 — available targets"
	@echo
	@grep -hE '^[a-zA-Z0-9_.-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Nominal sequence: make vms provision secrets certs build deploy smoke"

# =============================================================================
# Infrastructure
# =============================================================================
.PHONY: vms destroy provision provision-check hosts

vms: ## Create the 3 Ubuntu 24.04 VMs (Vagrant + VirtualBox)
	$(require_env)
	@if [ ! -f "$(ANSIBLE)/inventory/hosts.yml" ]; then \
	  cp "$(ANSIBLE)/inventory/hosts.yml.example" "$(ANSIBLE)/inventory/hosts.yml"; \
	  echo "-> created ansible/inventory/hosts.yml from the example"; \
	fi
	cd $(ROOT) && NODE_MEM=$${NODE_MEM:-6144} NODE_CPU=$${NODE_CPU:-4} vagrant up

destroy: ## Destroy the 3 VMs (irreversible)
	cd $(ROOT) && vagrant destroy -f

provision: ## Configure the hosts and the Swarm (Ansible)
	$(require_env)
	cd $(ANSIBLE) && ansible-playbook playbooks/site.yml

provision-check: ## Idempotency check — must report 0 changed (criterion 0.2)
	cd $(ANSIBLE) && ansible-playbook playbooks/site.yml --check --diff

hosts: ## Print the /etc/hosts line to add on the workstation
	@$(SCRIPTS)/hosts-entries.sh

# =============================================================================
# Secrets, certificates, images
# =============================================================================
.PHONY: secrets certs build pin-digests

secrets: ## Generate secrets/ and create the missing Docker secrets
	$(require_env)
	$(SCRIPTS)/init-secrets.sh

certs: ## Internal CA, wildcard certificate and Elasticsearch transport certs
	$(require_env)
	$(SCRIPTS)/gen-certs.sh
	$(SCRIPTS)/gen-es-certs.sh

build: ## Build the home-made images and push them to the internal registry
	$(require_env)
	$(SCRIPTS)/build-images.sh $(OWN_IMAGES)

pin-digests: ## Check that the digests pinned in stacks/ still match their tags
	$(SCRIPTS)/pin-digests.sh

# =============================================================================
# Deployment
# =============================================================================
.PHONY: deploy $(addprefix deploy-,$(STACK_ORDER)) deploy-registry deploy-demo status single

deploy: ## Deploy every stack in order, waiting for health between them
	$(require_env)
	$(SCRIPTS)/deploy.sh all

deploy-registry: ## Deploy the internal registry only
	$(require_env)
	$(SCRIPTS)/deploy.sh registry

$(addprefix deploy-,$(STACK_ORDER)): deploy-%: ## Deploy a single stack
	$(require_env)
	$(SCRIPTS)/deploy.sh $*

deploy-demo: ## Deploy the big-data demo producer (optional)
	$(require_env)
	$(SCRIPTS)/deploy.sh demo

status: ## Services, nodes and cluster health at a glance
	$(SCRIPTS)/status.sh

single: ## Single-node mode for a workstation (NOT highly available)
	$(require_env)
	$(SCRIPTS)/deploy.sh --single all

# =============================================================================
# Tests
# =============================================================================
.PHONY: smoke chaos dr-drill test-python

smoke: ## End-to-end validation through the VIP
	$(TESTS)/smoke/smoke.sh

chaos: ## HA test campaign (kill service, drain node, kill node)
	@mkdir -p $(REPORTS)
	$(TESTS)/chaos/run-all.sh

dr-drill: ## Automated disaster-recovery drill (restores, no production impact)
	@mkdir -p $(REPORTS)
	$(TESTS)/dr/dr-drill.sh

test-python: ## Unit tests of the home-made Python services
	cd $(ROOT)/images/alert2glpi && python3 -m pytest -q
	cd $(ROOT)/images/demo-producer && python3 -m pytest -q

# =============================================================================
# Backup and restore
# =============================================================================
.PHONY: backup-now restore-galera restore-glpi-files restore-cassandra restore-es
.PHONY: restore-prometheus restore-crowdsec restore-all

backup-now: ## Trigger every backup job immediately
	$(SCRIPTS)/backup-now.sh

restore-galera: ## Restore the SQL databases from the latest restic snapshot
	$(SCRIPTS)/restore/restore-galera.sh $(ARGS)

restore-glpi-files: ## Restore the GLPI NFS files
	$(SCRIPTS)/restore/restore-glpi-files.sh $(ARGS)

restore-cassandra: ## Restore the `datalake` keyspace (NODE=cassandra-1 …)
	$(SCRIPTS)/restore/restore-cassandra.sh $(NODE) $(ARGS)

restore-es: ## Restore Elasticsearch indices from a snapshot
	$(SCRIPTS)/restore/restore-es.sh $(ARGS)

restore-prometheus: ## Restore the Prometheus TSDB of instance A
	$(SCRIPTS)/restore/restore-prometheus.sh $(ARGS)

restore-crowdsec: ## Restore the CrowdSec LAPI database
	$(SCRIPTS)/restore/restore-crowdsec.sh $(ARGS)

restore-all: ## Full ordered restore of the platform
	$(SCRIPTS)/restore/restore-all.sh $(ARGS)

# =============================================================================
# Quality
# =============================================================================
.PHONY: lint lint-yaml lint-ansible lint-shell lint-docker lint-python lint-prom lint-stacks

lint: lint-yaml lint-ansible lint-shell lint-docker lint-python lint-prom lint-stacks ## Run every linter

lint-yaml: ## yamllint over the whole repository
	yamllint -c $(ROOT)/.yamllint.yml $(ROOT)

lint-ansible: ## ansible-lint (production profile)
	cd $(ANSIBLE) && ansible-lint

lint-shell: ## shellcheck over every shell script
	# The firewall script is a Jinja template; shellcheck parses it because every
	# substitution sits inside a quoted string or a comment.
	find $(ROOT) -type f -name '*.sh' -not -path '*/.git/*' -print0 \
	  | sort -z \
	  | xargs -0 -r shellcheck --external-sources --source-path=$(ROOT)/scripts --shell=bash
	shellcheck --external-sources --shell=bash \
	  $(ANSIBLE)/roles/firewall/templates/dockerwarts-firewall.sh.j2

lint-docker: ## hadolint over every Dockerfile
	@find $(ROOT)/images -name Dockerfile -print0 | xargs -0 -r hadolint

lint-python: ## ruff over the Python code (services + shared tooling)
	ruff check $(ROOT)/images $(SCRIPTS)/lib
	ruff format --check $(ROOT)/images $(SCRIPTS)/lib

lint-prom: ## promtool / amtool checks (same script as the CI)
	$(SCRIPTS)/validate-configs.sh

lint-stacks: ## Validate every stack with `docker stack config`
	$(SCRIPTS)/validate-stacks.sh

# =============================================================================
.PHONY: clean
clean: ## Remove local reports and generated artefacts (keeps secrets/ and certs/)
	rm -rf $(REPORTS)
	find $(ROOT) -name '__pycache__' -type d -prune -exec rm -rf {} +
	find $(ROOT) -name '.pytest_cache' -type d -prune -exec rm -rf {} +
