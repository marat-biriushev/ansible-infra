# ===================================================================
# Authentication for a CI run. Must be SOURCED, not executed, because
# it exports the ssh-agent socket / the Kerberos cache into the job:
#
#   . ci/setup-auth.sh
#
# Two modes, in order of preference:
#   KRB5_KEYTAB + KRB5_PRINCIPAL -> kinit, GSSAPI against FreeIPA
#   SSH_PRIVATE_KEY              -> ssh-agent with a deploy key
# ===================================================================

if [ -n "${KRB5_KEYTAB:-}" ]; then
    if [ -z "${KRB5_PRINCIPAL:-}" ]; then
        echo "KRB5_PRINCIPAL must be set together with KRB5_KEYTAB" >&2
        exit 2
    fi
    if ! command -v kinit >/dev/null 2>&1; then
        echo "kinit not found - the runner image needs the Kerberos client" >&2
        echo "  (krb5-user on Debian, krb5-workstation on RHEL)" >&2
        exit 2
    fi
    # KRB5CCNAME is set by the pipeline so the ticket lands in the job
    # workspace and disappears with it.
    if ! kinit -kt "$KRB5_KEYTAB" "$KRB5_PRINCIPAL"; then
        echo "kinit failed for $KRB5_PRINCIPAL - check the keytab and the clock skew" >&2
        exit 2
    fi
    klist
    echo "auth: Kerberos ticket for $KRB5_PRINCIPAL"

elif [ -n "${SSH_PRIVATE_KEY:-}" ]; then
    if ! command -v ssh-agent >/dev/null 2>&1; then
        echo "ssh-agent not found - the runner image needs openssh-client" >&2
        exit 2
    fi
    eval "$(ssh-agent -s)" >/dev/null
    install -m 0600 "$SSH_PRIVATE_KEY" "${CI_PROJECT_DIR:-/tmp}/.deploy_key"
    ssh-add "${CI_PROJECT_DIR:-/tmp}/.deploy_key"
    echo "auth: ssh key from SSH_PRIVATE_KEY"

else
    echo "no authentication configured: set KRB5_KEYTAB + KRB5_PRINCIPAL (IPA)" >&2
    echo "or SSH_PRIVATE_KEY in the project CI/CD variables" >&2
    exit 2
fi

if [ -n "${SSH_KNOWN_HOSTS:-}" ]; then
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    printf '%s\n' "$SSH_KNOWN_HOSTS" > ~/.ssh/known_hosts
    chmod 600 ~/.ssh/known_hosts
    ANSIBLE_HOST_KEY_CHECKING=True
    export ANSIBLE_HOST_KEY_CHECKING
    echo "auth: host key checking enabled from SSH_KNOWN_HOSTS"
fi
