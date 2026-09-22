# ansible

Ansible-репозиторий для всей инфраструктуры: раздельные инвентори по окружениям,
роли вынесены отдельно, плейбуки — отдельно.

Первый стек — отказоустойчивый кластер PostgreSQL 18 под управлением Patroni 4.1.x.

## Структура

```
ansible.cfg                  # настройки по умолчанию (inventory = test)
requirements.yml             # коллекции ansible-galaxy
Makefile                     # короткие команды: make patroni ENV=prod
inventories/
  dev/                       # dev-окружение
    integration.yml          # хосты: playmobile (app) + кластер БД
    group_vars/
      all/main.yml           # общие переменные окружения
      playmobile.yml         # настройки app-узлов проекта playmobile
    host_vars/
  test/                      # тестовое окружение
    integration.yml
    group_vars/
      all/main.yml
      all/vault.yml.example  # шаблон секретов (vault.yml шифруется ansible-vault)
      playmobile.yml
      patroni.yml            # параметры PostgreSQL/Patroni
      etcd.yml
      haproxy.yml
      keepalived.yml
    host_vars/
  prod/                      # продуктивное окружение (та же раскладка)
playbooks/
  site.yml                   # точка входа для всей инфраструктуры
  playmobile.yml             # app-узлы проекта playmobile (Docker)
  patroni_cluster.yml        # развёртывание кластера БД
  patroni_status.yml         # состояние кластера
  patroni_switchover.yml     # плановое переключение лидера
  patroni_rolling_restart.yml
roles/
  mirror/                    # репозитории и pip через корпоративное зеркало
  common/                    # базовая настройка ОС
  docker/                    # Docker CE + /etc/docker/daemon.json
  etcd/                      # etcd v3 (DCS для Patroni)
  postgresql/                # пакеты PostgreSQL 18 из PGDG
  patroni/                   # Patroni 4.1.x в venv + systemd
  haproxy/                   # маршрутизация rw/ro
  keepalived/                # VRRP VIP перед парой HAProxy
docs/                        # эксплуатационная документация
```

## Хосты

Группа `playmobile` — app-узлы одноимённого проекта, RHEL 10.2:

| Окружение | Хосты | Адреса | БД |
|---|---|---|---|
| dev  | `playm-dev-app01` | 172.31.125.51 | — |
| test | `playm-tst-app01…04` | 172.31.125.151-154 | 3 + 2 VM (адреса-заглушки) |
| prod | `playm-prd-01…06` | 172.31.126.51-56 | 3 + 2 VM (адреса-заглушки) |

## Docker на узлах playmobile

```bash
make playmobile ENV=dev                 # один узел
make playmobile ENV=prod LIMIT=playm-prd-01
```

Роль `docker` (технологическая, переиспользуемая) кладёт `/etc/yum.repos.d/docker-ce.repo` с
`baseurl=http://mirror.ipotekabank.uz/repos/docker/`, ставит
`docker-ce`, `docker-ce-cli`, `containerd.io`, buildx и compose-плагины и
разворачивает `/etc/docker/daemon.json`. Файл собирается из переменных
(`inventories/<env>/group_vars/playmobile.yml`), поэтому реестры и пул адресов
меняются по окружениям без правки роли:

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

Перед записью файл проверяется `dockerd --validate --config-file`, старая
версия сохраняется рядом (`backup: true`), демон перезапускается только
при реальном изменении. `gpgcheck` для репозитория выключен
(`docker_repo_gpgcheck: false`) — включите вместе с `docker_repo_gpgkey`,
когда на зеркале появится ключ.

## Топология стека БД

| Группа       | Кол-во | Роли на узле                          |
|--------------|--------|---------------------------------------|
| `patroni`    | 3 VM   | etcd + PostgreSQL 18 + Patroni 4.1.x  |
| `etcd`       | те же 3 VM | кворум DCS                        |
| `haproxy`    | 2 VM   | HAProxy                               |
| `keepalived` | те же 2 VM | VRRP VIP                          |

Точки подключения (через VIP):

| Порт   | Назначение                                |
|--------|-------------------------------------------|
| `5000` | read/write — всегда текущий лидер          |
| `5001` | read-only — живые реплики (round-robin)    |
| `7000` | статистика HAProxy (`/stats`)              |
| `8008` | Patroni REST API на узлах БД               |

## Быстрый старт

```bash
# 1. зависимости
make deps                       # ansible-galaxy collection install -r requirements.yml

# 2. секреты окружения
cp inventories/test/group_vars/all/vault.yml.example \
   inventories/test/group_vars/all/vault.yml
$EDITOR inventories/test/group_vars/all/vault.yml
ansible-vault encrypt inventories/test/group_vars/all/vault.yml
echo 'пароль-от-vault' > .vault_pass && chmod 600 .vault_pass   # файл в .gitignore

# 3. проверка связности и синтаксиса
make ping ENV=test
make syntax ENV=test
make lint

# 4. прогон вхолостую и развёртывание
make check ENV=test
make patroni ENV=test
```

Для прода: `make patroni ENV=prod` (инвентори `inventories/prod`).

## Эксплуатация

```bash
make status ENV=prod                              # patronictl list + show-config
make switchover ENV=prod CANDIDATE=pg-prod-db-02  # плановое переключение
make haproxy ENV=prod                             # только балансировщики
ansible-playbook -i inventories/prod playbooks/patroni_rolling_restart.yml
```

Подробности — в [docs/patroni-cluster.md](docs/patroni-cluster.md).

## Требования

* Ansible core >= 2.15 на управляющей машине, Python 3 на целевых узлах.
* Целевые ОС: **RHEL 9 и RHEL 10** (основная платформа), Debian 12 / Ubuntu 22.04+
  поддерживаются тем же кодом.
* Доступ по SSH с sudo без пароля (либо `--ask-become-pass`).
* Сетевая доступность между узлами: 5432, 8008 (Patroni), 2379/2380 (etcd),
  5000/5001/7000 (HAProxy), VRRP (протокол 112) между балансировщиками.
  На RHEL правила firewalld расставляют сами роли при `manage_firewall: true`.

## Корпоративное зеркало

Всё, что плейбуки скачивают, идёт через `http://mirror.ipotekabank.uz`
(роль `mirror` + переменные в `group_vars/all/main.yml`):

| Что | Переменная | Путь по умолчанию |
|---|---|---|
| Docker CE | `docker_repo_baseurl` | `/repos/docker/` (подтверждено) |
| PGDG для RHEL | `postgresql_pgdg_rhel_baseurl` | `/postgresql/repos/yum/18/redhat/rhel-$releasever-$basearch` |
| PGDG для Debian | `postgresql_pgdg_repo_url` | `/postgresql/repos/apt` |
| Архив etcd | `etcd_download_base_url` | `/etcd/v3.5.17/etcd-v3.5.17-linux-amd64.tar.gz` |
| Python-колёса | `mirror_pypi_index_url` | `/pypi/simple` (пишется в `/etc/pip.conf`) |
| BaseOS/AppStream | `mirror_rhel_*_url` | `/rhel/$releasever/{BaseOS,AppStream}/$basearch/os` |
| sources.list | `mirror_debian_url` | `/debian`, `/debian-security` |

Подтверждён только путь docker (`/repos/<name>/`), остальные приведены к
той же схеме, но их стоит сверить: если раскладка другая, поправьте
переменные в `inventories/<env>/group_vars/all/main.yml`, менять роли не нужно.

Базовые репозитории ОС по умолчанию **не трогаются**
(`mirror_manage_os_repos: false`) — обычно образы VM уже настроены на
зеркало. Поставьте `true`, если хотите, чтобы Ansible владел
`/etc/yum.repos.d` (старые `.repo` переименовываются в `*.repo.disabled`)
или `/etc/apt/sources.list` (оригинал сохраняется рядом).

Если зеркало не раздаёт GPG-ключ PGDG — `postgresql_pgdg_rhel_gpgcheck: false`.

## Соглашения

* Версии ПО задаются один раз в `group_vars/all/main.yml` окружения.
* Все пароли — только через `vault.yml`; в ролях лежат заведомо нерабочие
  значения-заглушки.
* Конфигурация кластера после первичного bootstrap хранится в DCS —
  меняется через `patronictl edit-config`, а не переписыванием `patroni.yml`.
* Перезапуск Patroni хендлером выключен (`patroni_allow_restart: false`),
  чтобы правка конфига не вызвала внеплановый failover: применяется reload
  (SIGHUP), а рестарт — отдельным плейбуком.
