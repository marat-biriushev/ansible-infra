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
  test/                      # тестовое окружение
    hosts.yml
    group_vars/
      all/main.yml           # общие переменные окружения
      all/vault.yml.example  # шаблон секретов (vault.yml шифруется ansible-vault)
      patroni.yml            # параметры PostgreSQL/Patroni
      etcd.yml
      haproxy.yml
      keepalived.yml
    host_vars/
  prod/                      # продуктивное окружение (та же раскладка)
playbooks/
  site.yml                   # точка входа для всей инфраструктуры
  patroni_cluster.yml        # развёртывание кластера
  patroni_status.yml         # состояние кластера
  patroni_switchover.yml     # плановое переключение лидера
  patroni_rolling_restart.yml
roles/
  common/                    # базовая настройка ОС
  etcd/                      # etcd v3 (DCS для Patroni)
  postgresql/                # пакеты PostgreSQL 18 из PGDG
  patroni/                   # Patroni 4.1.x в venv + systemd
  haproxy/                   # маршрутизация rw/ro
  keepalived/                # VRRP VIP перед парой HAProxy
docs/                        # эксплуатационная документация
```

## Топология первого стека

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
* Целевые ОС: Debian 12 / Ubuntu 22.04+ либо RHEL-совместимые 8/9.
* Доступ по SSH с sudo без пароля (либо `--ask-become-pass`).
* Сетевая доступность между узлами: 5432, 8008 (Patroni), 2379/2380 (etcd),
  5000/5001/7000 (HAProxy), VRRP (протокол 112) между балансировщиками.

## Соглашения

* Версии ПО задаются один раз в `group_vars/all/main.yml` окружения.
* Все пароли — только через `vault.yml`; в ролях лежат заведомо нерабочие
  значения-заглушки.
* Конфигурация кластера после первичного bootstrap хранится в DCS —
  меняется через `patronictl edit-config`, а не переписыванием `patroni.yml`.
* Перезапуск Patroni хендлером выключен (`patroni_allow_restart: false`),
  чтобы правка конфига не вызвала внеплановый failover: применяется reload
  (SIGHUP), а рестарт — отдельным плейбуком.
