# ansible

Infrastructure repository: one place for every stack we run, with
separate inventories per environment, reusable roles and one playbook per
project.

## Layout

```
ansible.cfg                  # defaults (inventory = test)
requirements.yml             # galaxy collections
Makefile                     # shortcuts: make play ENV=prod PLAYBOOK=...
inventories/
  dev/ test/ prod/           # one directory per environment
    <project>.yml            # hosts of a project, grouped by role in it
    group_vars/
      all/main.yml           # environment-wide settings and versions
      all/vault.yml.example  # template for the encrypted secrets
      <group>.yml            # settings of one inventory group
    host_vars/
playbooks/
  site.yml                   # imports every project playbook
  <project>.yml              # one project, built from roles
roles/
  <technology>/              # reusable, named after what it installs
docs/
  <project>.md               # how a stack is deployed and operated
```

Directories `files/`, `library/` and `filter_plugins/` are placeholders
for shared artefacts, custom modules and custom filters.

## Conventions

* **Environments are separate inventories.** `dev`, `test` and `prod`
  never share a file; the same playbook is run against a different `-i`.
* **Inventory files are named after the project**, not after a host
  class, and hold every group that project needs. One project may
  contain several groups (application nodes, database nodes, load
  balancers).
* **Roles are named after the technology** they install (`docker`,
  `postgresql`, `patroni`, `haproxy`) and stay reusable: nothing inside a
  role refers to a project. The binding between a project and the roles
  it uses lives in `playbooks/<project>.yml`.
* **A value is defined once.** Versions, ports, mirror paths and network
  ranges live in `inventories/<env>/group_vars/all/main.yml` and are
  referenced everywhere else; role defaults only provide a working
  fallback for a role used outside this repository.
* **Secrets never enter the repository.** Only `vault.yml.example` with
  placeholders is committed; the real `vault.yml` is encrypted with
  `ansible-vault` and the password stays out of git.
* **The OS baseline is not ours.** See *Separation of duties* below.
* **Every change is linted before it is committed**: `make lint` and
  `make syntax`.

## Running playbooks

```bash
make deps                                  # galaxy collections
make ping  ENV=test                        # connectivity
make lint                                  # yamllint + ansible-lint
make syntax ENV=test                       # --syntax-check

make play ENV=test PLAYBOOK=playbooks/<project>.yml CHECK=1   # dry run
make play ENV=test PLAYBOOK=playbooks/<project>.yml           # apply
make play ENV=prod PLAYBOOK=playbooks/<project>.yml LIMIT=host1 TAGS=config
make play ENV=dev  PLAYBOOK=playbooks/<project>.yml ASK=1     # ask for the passwords
```

Without the Makefile it is the usual invocation:

```bash
ansible-playbook -i inventories/prod playbooks/<project>.yml \
  --limit <host-or-group> --tags <tags> --check --diff
```

`--check --diff` first is the habit worth keeping: it prints what would
change without changing it.

## Adding a project

1. `inventories/<env>/<project>.yml` - the hosts, in groups named after
   their function in the project.
2. `inventories/<env>/group_vars/<group>.yml` - the settings of that
   group; anything shared by the whole environment goes to
   `group_vars/all/main.yml`.
3. `roles/<technology>/` - a new role only if no existing one installs
   that software; keep it free of project-specific names.
4. `playbooks/<project>.yml` - binds the groups to the roles.
5. Import it from `playbooks/site.yml`.
6. `docs/<project>.md` - what it deploys, how it is operated, what is
   specific about it.
7. `make lint && make syntax ENV=<env>` before committing.

## Secrets

```bash
cp inventories/test/group_vars/all/vault.yml.example \
   inventories/test/group_vars/all/vault.yml
$EDITOR inventories/test/group_vars/all/vault.yml
ansible-vault encrypt inventories/test/group_vars/all/vault.yml
echo 'vault-password' > .vault_pass && chmod 600 .vault_pass  # gitignored
export ANSIBLE_VAULT_PASSWORD_FILE=.vault_pass
```

Roles carry deliberately non-working placeholder passwords, so a missing
vault fails loudly instead of deploying something with a default
password.

## Corporate mirror

Everything the playbooks download comes from the internal mirror, set per
environment in `group_vars/all/main.yml`:

| Variable | What it points at |
|---|---|
| `mirror_base_url` | the mirror itself |
| `docker_repo_baseurl` | Docker CE repository |
| `postgresql_pgdg_rhel_baseurl` | PGDG for the RHEL family |
| `postgresql_pgdg_repo_url` | PGDG for the Debian family |
| `etcd_download_base_url` | etcd release archives |
| `mirror_pypi_index_url` | Python wheels |

The `mirror` role can also repoint the base OS repositories
(`mirror_manage_os_repos`, off by default - the images normally already
come from the mirror).

`galaxy.ansible.com` is not reachable from the network either: install
the collections from an internal Galaxy proxy
(`make deps GALAXY=<url>`, or the commented `[galaxy_server.internal]`
section in `ansible.cfg`), or vendor the tarballs.

## Access

Hosts are enrolled in FreeIPA. Any of the three login methods works; the
repository does not force one.

```bash
ansible -i inventories/<env> <group> -m ping -k -K   # password
kinit && ansible -i inventories/<env> <group> -m ping  # kerberos ticket
```

* **Password** (`-k`) needs `sshpass` on the control node: the `ssh`
  connection plugin shells out to it and, without it, fails with
  `No such file or directory: b'sshpass'`, which does not say what is
  missing. Install it from EPEL, or use the `paramiko` connection plugin
  (`pip install paramiko`, then `-c paramiko`), which handles the
  password itself but has no connection multiplexing and is slower.
* **Key or Kerberos** needs nothing extra. `ansible.cfg` passes
  `-o GSSAPIAuthentication=yes`; do not put
  `PreferredAuthentications=publickey` back, it disables Kerberos. A
  Kerberos login also needs the clock within the 5 minute skew - the
  `common` role checks that before anything is deployed.
* **sudo**: `-K` when the rule (from IPA or local) asks for a password.

Per-environment settings that depend on how IPA is configured
(`ansible_user`, `ansible_become_password` when the sudo rule is not
NOPASSWD, `VerifyHostKeyDNS` for the SSHFP records IPA publishes) are
prepared, commented, in `group_vars/all/main.yml`.

`host_key_checking` is currently `False` in `ansible.cfg`. With IPA
publishing SSHFP records it is worth turning on.

## Separation of duties

The infrastructure team owns the OS baseline of these machines, so the
`common` role changes nothing by default:

| Area | Variable | Default |
|---|---|---|
| packages | `common_manage_packages` | `false` |
| timezone | `common_manage_timezone` | `false` |
| chrony / NTP | `common_manage_chrony` | `false` |
| sysctl | `common_manage_sysctl` | `false` |
| `/etc/hosts` | `common_manage_hosts_file` | `false` |
| clock check | `common_verify_time_sync` | `true`, read-only |

Instead of configuring time, the role verifies it (`timedatectl` plus
`chronyc tracking`) and stops with an explanation when the clock is not
disciplined - drift costs a Patroni lease, an etcd leader and a Kerberos
ticket. Disable with `-e common_verify_time_sync=false`, downgrade to a
warning with `-e common_time_sync_fail=false`.

When a stack really needs a baseline change, it is enabled explicitly in
the inventory where a reviewer sees it - as `common_manage_sysctl: true`
in `group_vars/patroni.yml`, which is PostgreSQL kernel tuning written to
a dedicated file in `/etc/sysctl.d/`.

The same rule applies everywhere else: changes go to a dedicated file
rather than a shared one (`/etc/security/limits.d/90-postgresql.conf`,
not `limits.conf`), tools are installed by the role that needs them
rather than by a shared package list, the pip index is passed to the one
virtualenv that needs it rather than written to `/etc/pip.conf`, and
anything that does touch a shared file keeps a backup.

## Requirements

* Ansible core >= 2.15 on the control machine (verified against 2.15.13
  on Python 3.9), Python 3 on the targets.
* `ansible.cfg` is read from the current directory, so run everything
  from the repository root - `ansible --version` must print the config
  file, not `None`. Ansible also ignores a config file in a
  world-writable directory.
* Collections are only needed by the database stack; a playbook built
  from `ansible.builtin` modules alone (such as the docker one) runs on
  a control node with no galaxy access.
* Targets: RHEL 9 and RHEL 10 (primary), Debian 12 / Ubuntu 22.04+ also
  supported.
* SSH access with sudo (Kerberos through IPA, see *Access*).

There is no CI in the repository at the moment: run `make lint` and
`make syntax` by hand before committing. A GitLab pipeline and a GitHub
workflow existed in earlier commits and can be restored from git history
when they are needed.

## Projects

| Project | Playbook | Docs |
|---|---|---|
| playmobile | `playbooks/playmobile.yml` | [docs/playmobile.md](docs/playmobile.md) |
| PostgreSQL HA (Patroni) | `playbooks/patroni_cluster.yml` | [docs/patroni-cluster.md](docs/patroni-cluster.md) |
