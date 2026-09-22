# Кластер Patroni: развёртывание и эксплуатация

## Что разворачивается

1. **etcd v3** (3 узла, на тех же VM, что и БД) — DCS, хранит состояние
   кластера и результат выборов лидера. Кворум — 2 из 3.
2. **PostgreSQL 18** из репозитория PGDG (на RHEL — `.repo`-файл на зеркало,
   без `pgdg-redhat-repo` RPM). Пакетный кластер (`main` на Debian) не
   создаётся и сервис маскируется — данными управляет Patroni.
3. **Patroni 4.1.x** — в отдельном virtualenv `/opt/patroni`, unit
   `patroni.service`, конфиг `/etc/patroni/patroni.yml`.
4. **HAProxy** (2 узла) — проверяет Patroni REST API и отдаёт на порт 5000
   только лидера, на 5001 — реплики.
5. **keepalived** — VRRP VIP перед парой HAProxy, отслеживает живость HAProxy.

## Порядок развёртывания

Плейбук `playbooks/patroni_cluster.yml` выполняет:

1. preflight — проверка топологии (>= 3 узла БД, нечётное число etcd,
   2 балансировщика, ровно один `MASTER` в keepalived), поддерживаемости
   ОС (RHEL 9/10 или Debian), существования `cluster_interface` на
   балансировщиках и наличия секретов;
2. `common` — проверка синхронизации времени, только чтение; базовую
   настройку ОС роль не меняет вообще;
3. `etcd` — бинарники, конфиг, systemd, ожидание healthy-эндпоинта;
4. `postgresql` — репозиторий PGDG, пакеты, каталоги, лимиты, при явном
   разрешении — sysctl-тюнинг;
5. `patroni` — venv, конфиг, unit; первым стартует
   `groups['patroni'][0]` и выполняет bootstrap (initdb), остальные узлы
   поднимаются репликами через `pg_basebackup`;
6. `haproxy` + `keepalived` — маршрутизация, VIP, SELinux и firewalld;
7. итоговая сводка с `patronictl list` и строками подключения.

Плейбук идемпотентен: повторный прогон не пересоздаёт кластер, а приводит
конфигурацию к описанной.

## Проверка после установки

```bash
# состояние кластера
patronictl -c /etc/patroni/patroni.yml list

# здоровье etcd
etcdctl endpoint status --write-out=table

# маршрутизация: должен ответить лидер
psql "host=<VIP> port=5000 user=postgres" -c "select pg_is_in_recovery();"   # f
psql "host=<VIP> port=5001 user=postgres" -c "select pg_is_in_recovery();"   # t
```

## Типовые операции

| Задача | Команда |
|---|---|
| Состояние | `ansible-playbook -i inventories/prod playbooks/patroni_status.yml` |
| Плановое переключение | `ansible-playbook -i inventories/prod playbooks/patroni_switchover.yml -e candidate=pg-prod-db-02` |
| Rolling restart | `ansible-playbook -i inventories/prod playbooks/patroni_rolling_restart.yml` |
| Изменить параметры PostgreSQL | `patronictl -c /etc/patroni/patroni.yml edit-config` |
| Пересобрать реплику | `patronictl -c /etc/patroni/patroni.yml reinit <scope> <node>` |
| Пауза автоматического failover | `patronictl -c /etc/patroni/patroni.yml pause <scope>` |

## Важные нюансы

* **Параметры PostgreSQL после bootstrap.** Секция `bootstrap.dcs` в
  `patroni.yml` применяется только при первичном создании кластера. Дальше
  источник истины — DCS: правьте через `patronictl edit-config`, иначе
  изменения в `group_vars` не доедут до работающего кластера.
* **synchronous_mode.** В проде включён (`synchronous_node_count: 1`) —
  это гарантия отсутствия потери транзакций при failover ценой задержки
  коммита. В тесте выключен.
* **watchdog.** По умолчанию `off`, так как в VM обычно нет `/dev/watchdog`.
  Если устройство есть — переведите `patroni_watchdog_mode: automatic`.
* **Чужая зона ответственности.** Роль `common` ничего не меняет — она
  только проверяет синхронизацию времени: базовая настройка ОС
  принадлежит команде инфраструктуры. Единственное, что включено в
  `group_vars/patroni.yml`, — `postgresql_manage_sysctl: true` (тюнинг
  ядра под PostgreSQL в отдельном файле `/etc/sysctl.d/`). Перед прогоном
  плейбук проверяет, что часы синхронизированы, и останавливается, если
  нет.
* **Рестарт Patroni.** Хендлер `Restart patroni` защищён переменной
  `patroni_allow_restart` (по умолчанию `false`), потому что рестарт на
  лидере означает failover. Штатный путь — reload или rolling-restart плейбук.
* **VIP и HAProxy.** На балансировщиках включён `net.ipv4.ip_nonlocal_bind=1`,
  поэтому HAProxy слушает VIP и на BACKUP-узле.
* **etcd initial-cluster-state.** Вычисляется по наличию каталога
  `<data_dir>/member`: `new` при первичном bootstrap, `existing` дальше —
  повторный прогон роли не ломает работающий кворум.

## Особенности RHEL 9 / 10

* **Пути данных.** На RHEL кластер живёт в `/var/lib/pgsql/18/data`
  (метка SELinux `postgresql_db_t`), логи PostgreSQL — в `data/log`.
  На Debian — `/var/lib/postgresql/18/data` и `/var/log/postgresql`.
  Задаётся картами `postgresql_home_by_os` / `postgresql_bin_dir_by_os`,
  так что перенос каталога переопределяется одной переменной (при
  нестандартном пути на RHEL потребуется `semanage fcontext`).
* **Модульность.** `dnf module disable postgresql` выполняется только на
  RHEL 9 — в RHEL 10 модулей больше нет.
* **SELinux.** Роль `haproxy` включает `haproxy_connect_any` и пытается
  пометить порты 5000/5001/7000 как `haproxy_port_t`. Скрипт проверки
  keepalived использует `pidof`, а не `systemctl`: домен `keepalived_t`
  не имеет права обращаться к systemd.
* **firewalld.** При `manage_firewall: true` (включено в прод-инвентори)
  роли открывают только то, что нужно, и только нужным источникам:
  etcd 2379/2380 — между членами кластера, 8008 — узлы БД и
  балансировщики, 5432 и порты HAProxy — из `trusted_networks`,
  VRRP — между балансировщиками.
* **Пакеты.** Списки базовых пакетов разнесены по
  `roles/common/vars/{RedHat,Debian}.yml`: на RHEL не ставится `curl`
  (конфликт с `curl-minimal`) и `htop` (его нет без EPEL), зато
  добавлены `policycoreutils-python-utils` и `glibc-langpack-en` для
  локали `en_US.UTF-8`, которую использует initdb.
* **Имя интерфейса.** `cluster_interface` (по умолчанию `eth0`) на RHEL
  обычно `ens192`/`enp0s3` — preflight падает с понятным сообщением,
  если интерфейса нет.

## Расширение репозитория

Новый стек добавляется так: роль в `roles/`, плейбук в `playbooks/`,
группа хостов в `inventories/<env>/integration.yml`, переменные в
`inventories/<env>/group_vars/<группа>.yml`, импорт плейбука в
`playbooks/site.yml`. Так добавлен проект playmobile: группа
`playmobile`, роль `roles/docker`, плейбук `playbooks/playmobile.yml`.
