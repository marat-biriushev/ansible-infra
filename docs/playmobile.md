# Проект playmobile

App-узлы проекта: RHEL 10, Docker CE с корпоративного зеркала.

## Хосты

| Окружение | Хосты | Адреса |
|---|---|---|
| dev  | `playm-dev-app01` | 172.31.125.51 |
| test | `playm-tst-app01…04` | 172.31.125.151-154 |
| prod | `playm-prd-01…06` | 172.31.126.51-56 |

Группа в инвентори — `playmobile`, файл `inventories/<env>/integration.yml`.

## Запуск вручную

Проверено на ansible-core 2.15.13 / Python 3.9 — версии с рабочего
терминального сервера.

```bash
cd /path/to/ansible                      # ОБЯЗАТЕЛЬНО: ansible.cfg берётся из CWD
ansible --version | grep 'config file'   # должен показать .../ansible.cfg, не None

# 1. связность и sudo (-k спросит пароль SSH, -K — пароль sudo)
ansible -i inventories/dev playmobile -m ping -k -K
ansible -i inventories/dev playmobile -m command -a 'id' -k -K --become

# 2. что именно изменится
ansible-playbook -i inventories/dev playbooks/playmobile.yml -k -K --check --diff

# 3. прогон
ansible-playbook -i inventories/dev playbooks/playmobile.yml -k -K
```

Пароль спрашивается один раз и переиспользуется для всех хостов группы.
Полезные флаги: `-u <user>` — если удалённая учётка отличается от
локальной, `--limit playm-prd-01` — один узел, `-vv` — подробности при
разборе ошибки.

### Аутентификация: пароль, ключ или Kerberos

Репозиторий не навязывает способ входа, но у парольного есть требование,
о котором ansible сообщает невнятно.

* **Пароль (`-k`).** Стандартный connection-плагин `ssh` не умеет сам
  вводить пароль — он вызывает внешний `sshpass`. Если его нет:

  ```
  Unable to execute ssh command line on a controller due to:
  [Errno 2] No such file or directory: b'sshpass'
  ```

  Ставится из EPEL: `sudo dnf install sshpass`.

* **Пароль без `sshpass`.** Плагин `paramiko` вводит пароль сам
  (библиотека Python, внешняя утилита не нужна) — он входит в
  ansible-core:

  ```bash
  pip install paramiko          # в ваш venv, индекс с зеркала
  ansible-playbook -c paramiko -i inventories/dev playbooks/playmobile.yml -k -K
  ```

  Минус: `paramiko` не поддерживает мультиплексирование соединений
  (`ControlMaster`), поэтому прогон заметно медленнее.

* **Ключ или Kerberos.** Работают без дополнительных пакетов: положите
  ключ (`ssh-copy-id`) или получите тикет (`kinit`) и запускайте без
  `-k`. `ansible.cfg` уже передаёт `-o GSSAPIAuthentication=yes`.
  Для регулярных прогонов это предпочтительнее — не нужно вводить
  пароль и не нужен `sshpass`.

* **sudo.** `-K` нужен, если правило sudo (из IPA или локальное) требует
  пароль. Если правило NOPASSWD — флаг можно не указывать.

То же через Makefile:

```bash
make play ENV=dev  PLAYBOOK=playbooks/playmobile.yml CHECK=1
make play ENV=prod PLAYBOOK=playbooks/playmobile.yml LIMIT=playm-prd-01
```

### Что важно знать перед первым прогоном

* **Коллекции не нужны.** Роль `docker` использует только модули
  `ansible.builtin`, так что `ansible-galaxy` для этого плейбука не
  требуется — проверено прогоном с пустым путём коллекций.
* **`config file = None`** означает, что вы не в каталоге репозитория:
  ansible читает `ansible.cfg` из текущего каталога. Без него не
  подхватятся `roles_path`, `become` и настройки SSH. Ansible также
  игнорирует `ansible.cfg` в каталоге, доступном на запись всем, —
  проверьте права, если файл не подхватывается.
* **`--check` на узле, где репозитория Docker ещё нет, упадёт** на шаге
  установки: dnf в режиме проверки не видит пакет, потому что repo-файл
  в этом режиме не записывается. Это не поломка роли — либо запускайте
  без `--check`, либо повторите проверку после первого реального
  прогона.
* **Роль `common` сюда не подключена** — базовую настройку ОС на этих
  узлах делает команда инфраструктуры (см. «Separation of duties» в
  README).

Плейбук состоит из одной роли `docker` — базовую настройку ОС на этих
узлах делает команда инфраструктуры, поэтому роль `common` сюда не
подключена (см. раздел «Separation of duties» в README).

## Что делает роль

1. `/etc/yum.repos.d/docker-ce.repo` — повторяет файл, с которым узлы
   уже работают:

```ini
[docker-ce-stable]
name=Docker CE Stable - Local Mirror
baseurl=https://mirror.ipotekabank.uz/repos/docker/rhel/$releasever/$basearch/stable
enabled=1
gpgcheck=0
repo_gpgcheck=0
gpgkey=https://mirror.ipotekabank.uz/repos/docker/gpg/docker-rpm.gpg
metadata_expire=6h
```

   Плюс строка-маркер `# Ansible managed` сверху. Все значения —
   переменные (`docker_repo_baseurl`, `docker_repo_gpgkey`,
   `docker_repo_description`, `docker_repo_metadata_expire`).
2. Пакеты: `docker-ce`, `docker-ce-cli`, `containerd.io`,
   `docker-buildx-plugin`, `docker-compose-plugin`.
3. `/etc/docker/daemon.json` — собирается из переменных
   `inventories/<env>/group_vars/playmobile.yml`:

```json
{
    "log-driver": "json-file",
    "log-opts": {"max-size": "100m", "max-file": "3"},
    "insecure-registries": ["docker-asbt.nexus.otp.ipotekabank.uz",
                            "docker-proxy.nexus.otp.ipotekabank.uz"],
    "live-restore": true,
    "default-address-pools": [{"base": "100.100.0.0/16", "size": 24}]
}
```

4. Запуск и включение сервиса, вывод версии демона и действующих настроек.

## Нюансы

* **Валидация конфига.** `daemon.json` проверяется
  `dockerd --validate --config-file` до записи, предыдущая версия
  сохраняется рядом (`backup: true`). Битый конфиг не уронит демон.
* **Рестарт.** Демон перезапускается только при реальном изменении
  `daemon.json` (handler), а не на каждом прогоне.
* **GPG.** `gpgcheck=0` и `repo_gpgcheck=0` — как в файле, который уже
  работает на узлах. Ключ при этом на зеркале лежит и прописан в репо,
  так что включение проверки — это `docker_repo_gpgcheck: true` и
  `docker_repo_repo_gpgcheck: true`, без других правок. Стоит включить,
  когда будет время проверить подписи пакетов на зеркале.
* **module_hotfixes.** Выключен — в рабочем файле на RHEL 10 его нет, и
  модульности там больше не существует. Если узлы на RHEL 9 и dnf
  ругается на конфликт `containerd.io` с модулем `container-tools`,
  включите `docker_repo_module_hotfixes: true`.
* **podman.** Удаление конфликтующих пакетов выключено
  (`docker_remove_conflicting_packages: false`). Включите, если на
  app-узлах podman не нужен.
* **Реестры.** `insecure-registries` перечислены по HTTP-имени Nexus;
  если появится TLS с корпоративным CA, правильнее убрать их отсюда и
  раскатать CA на узлы.
