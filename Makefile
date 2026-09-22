# Environment to act on: dev | test | prod
ENV ?= test
INV  = inventories/$(ENV)
LIMIT ?=
TAGS ?=
EXTRA ?=

ANSIBLE_OPTS = -i $(INV) $(if $(LIMIT),--limit $(LIMIT),) $(if $(TAGS),--tags $(TAGS),) $(EXTRA)

.PHONY: help deps lint syntax ping play check patroni haproxy playmobile site switchover status

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-14s\033[0m %s\n", $$1, $$2}'

# Internal ansible-galaxy proxy, e.g.
#   make deps GALAXY=http://nexus.otp.ipotekabank.uz/repository/ansible-galaxy/
GALAXY ?=

deps: ## Install galaxy collections (GALAXY=<url> for an internal proxy)
	ansible-galaxy collection install -r requirements.yml $(if $(GALAXY),-s $(GALAXY),)

lint: ## Run yamllint + ansible-lint
	yamllint .
	ansible-lint

syntax: ## Syntax check all playbooks
	ansible-playbook $(ANSIBLE_OPTS) playbooks/site.yml --syntax-check

ping: ## Check connectivity
	ansible $(ANSIBLE_OPTS) all -m ping

play: ## Run any playbook: make play ENV=prod PLAYBOOK=playbooks/x.yml [LIMIT=] [TAGS=] [CHECK=1]
	@test -n "$(PLAYBOOK)" || { echo "PLAYBOOK is required, e.g. PLAYBOOK=playbooks/site.yml"; exit 2; }
	ansible-playbook $(ANSIBLE_OPTS) $(PLAYBOOK) $(if $(CHECK),--check --diff,)

check: ## Dry-run the patroni cluster playbook
	ansible-playbook $(ANSIBLE_OPTS) playbooks/patroni_cluster.yml --check --diff

patroni: ## Deploy the patroni cluster
	ansible-playbook $(ANSIBLE_OPTS) playbooks/patroni_cluster.yml

playmobile: ## Install/refresh Docker on the playmobile application nodes
	ansible-playbook $(ANSIBLE_OPTS) playbooks/playmobile.yml

haproxy: ## Deploy only the haproxy/keepalived layer
	ansible-playbook $(ANSIBLE_OPTS) playbooks/patroni_cluster.yml --tags haproxy,keepalived

site: ## Run the whole infrastructure playbook
	ansible-playbook $(ANSIBLE_OPTS) playbooks/site.yml

status: ## Show patroni cluster state
	ansible-playbook $(ANSIBLE_OPTS) playbooks/patroni_status.yml

switchover: ## Planned switchover (CANDIDATE=<host>)
	ansible-playbook $(ANSIBLE_OPTS) playbooks/patroni_switchover.yml -e "candidate=$(CANDIDATE)"
