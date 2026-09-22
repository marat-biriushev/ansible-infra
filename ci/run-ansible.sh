#!/bin/sh
# ===================================================================
# Wrapper used by the GitLab pipeline (and usable by hand) to turn the
# pipeline form into an ansible invocation:
#
#   ENVIRONMENT=prod PLAYBOOK=playbooks/playmobile.yml LIMIT=playm-prd-01 \
#     ci/run-ansible.sh check
#
# Arguments are passed through "$@" rather than a string, so a value
# with spaces (EXTRA_VARS="a=1 b=2") stays one argument.
# ===================================================================
set -eu

action=${1:-apply}

ENVIRONMENT=${ENVIRONMENT:-}
PLAYBOOK=${PLAYBOOK:-}
LIMIT=${LIMIT:-}
TAGS=${TAGS:-}
EXTRA_VARS=${EXTRA_VARS:-}

trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
ENVIRONMENT=$(trim "$ENVIRONMENT")
PLAYBOOK=$(trim "$PLAYBOOK")
LIMIT=$(trim "$LIMIT")
TAGS=$(trim "$TAGS")
EXTRA_VARS=$(trim "$EXTRA_VARS")

case "$ENVIRONMENT" in
    dev | test | prod) ;;
    *)
        echo "ENVIRONMENT must be one of dev|test|prod (got '$ENVIRONMENT')" >&2
        exit 2
        ;;
esac

if [ "$action" != "ping" ]; then
    case "$PLAYBOOK" in
        playbooks/*.yml) ;;
        *)
            echo "PLAYBOOK must be a file under playbooks/ (got '$PLAYBOOK')" >&2
            exit 2
            ;;
    esac
    if [ ! -f "$PLAYBOOK" ]; then
        echo "PLAYBOOK '$PLAYBOOK' does not exist" >&2
        exit 2
    fi
fi

set -- -i "inventories/$ENVIRONMENT"
if [ -n "$LIMIT" ]; then set -- "$@" --limit "$LIMIT"; fi
if [ -n "$TAGS" ]; then set -- "$@" --tags "$TAGS"; fi
if [ -n "$EXTRA_VARS" ]; then set -- "$@" --extra-vars "$EXTRA_VARS"; fi

case "$action" in
    ping)
        echo "+ ansible $* ${LIMIT:-all} -m ping"
        exec ansible "$@" "${LIMIT:-all}" -m ping
        ;;
    check)
        echo "+ ansible-playbook $* --check --diff $PLAYBOOK"
        exec ansible-playbook "$@" --check --diff "$PLAYBOOK"
        ;;
    apply)
        echo "+ ansible-playbook $* $PLAYBOOK"
        exec ansible-playbook "$@" "$PLAYBOOK"
        ;;
    *)
        echo "usage: $0 {ping|check|apply}" >&2
        exit 2
        ;;
esac
