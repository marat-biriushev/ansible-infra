# Environment to act on: dev | test | prod
ENV ?= test
INV  = inventories/$(ENV)

PLAYBOOK ?=
LIMIT ?=
TAGS ?=
EXTRA ?=
# CHECK=1 adds --check --diff
CHECK ?=
# ASK=1 adds -k -K (needs sshpass on the control node, or CONNECTION=paramiko)
ASK ?=
CONNECTION ?=
# GALAXY=<url> points make deps at an internal ansible-galaxy proxy
GALAXY ?=

OPTS = -i $(INV) \
       $(if $(LIMIT),--limit $(LIMIT),) \
       $(if $(TAGS),--tags $(TAGS),) \
       $(if $(ASK),-k -K,) \
       $(if $(CONNECTION),-c $(CONNECTION),) \
       $(if $(CHECK),--check --diff,) \
       $(EXTRA)

.PHONY: help deps lint syntax ping play

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-10s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "make play ENV=prod PLAYBOOK=playbooks/playmobile.yml [LIMIT=] [TAGS=] [CHECK=1] [ASK=1]"

deps: ## Install galaxy collections (GALAXY=<url> for an internal proxy)
	ansible-galaxy collection install -r requirements.yml $(if $(GALAXY),-s $(GALAXY),)

lint: ## yamllint + ansible-lint
	yamllint .
	ansible-lint

syntax: ## Syntax check every playbook
	ansible-playbook -i $(INV) playbooks/site.yml --syntax-check

ping: ## Check connectivity
	ansible $(OPTS) $(if $(LIMIT),$(LIMIT),all) -m ping

play: ## Run a playbook (PLAYBOOK is required)
	@test -n "$(PLAYBOOK)" || { echo "PLAYBOOK is required, e.g. PLAYBOOK=playbooks/site.yml"; exit 2; }
	ansible-playbook $(OPTS) $(PLAYBOOK)
