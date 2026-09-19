# Кластер Patroni: развёртывание и эксплуатация

## Что разворачивается

1. **etcd v3** (3 узла, на тех же VM, что и БД) — DCS, хранит состояние
   кластера и результат выборов лидера. Кворум — 2 из 3.
2. **PostgreSQL 18** из репозитория PGDG. Пакетный кластер (`main` на Debian)
   не создаётся и сервис маскируется — данными управляет Patroni.
3. **Patroni 4.1.x** — в отдельном virtualenv `/opt/patroni`, unit
   `patroni.service`, конфиг `/etc/patroni/patroni.yml`.
4. **HAProxy** (2 узла) — проверяет Patroni REST API и отдаёт на порт 5000
   только лидера, на 5001 — реплики.
5. **keepalived** — VRRP VIP перед парой HAProxy, отслеживает живость HAProxy.

## Порядок развёртывания

Плейбук `playbooks/patroni_cluster.yml` выполняет:

1. preflight — проверка топологии (>= 3 узла БД, нечётное число etcd,
   2 балансировщика, ровно один `MASTER` в keepalived) и наличия секретов;
2. `common` — время, NTP, sysctl, /etc/hosts;
3. `etcd` — бинарники, конфиг, systemd, ожидание healthy-эндпоинта;
4. `postgresql` — репозиторий PGDG, пакеты, каталоги, лимиты;
5. `patroni` — venv, конфиг, unit; первым стартует
   `groups['patroni'][0]` и выполняет bootstrap (initdb), остальные узлы
   поднимаются репликами через `pg_basebackup`;
6. `haproxy` + `keepalived` — маршрутизация и VIP;
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
| Состояние | `make status ENV=prod` |
| Плановое переключение | `make switchover ENV=prod CANDIDATE=pg-prod-db-02` |
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
* **Рестарт Patroni.** Хендлер `Restart patroni` защищён переменной
  `patroni_allow_restart` (по умолчанию `false`), потому что рестарт на
  лидере означает failover. Штатный путь — reload или rolling-restart плейбук.
* **VIP и HAProxy.** На балансировщиках включён `net.ipv4.ip_nonlocal_bind=1`,
  поэтому HAProxy слушает VIP и на BACKUP-узле.
* **etcd initial-cluster-state.** Вычисляется по наличию каталога
  `<data_dir>/member`: `new` при первичном bootstrap, `existing` дальше —
  повторный прогон роли не ломает работающий кворум.

## Расширение репозитория

Новый стек добавляется так: роль в `roles/`, плейбук в `playbooks/`,
переменные в `inventories/<env>/group_vars/<группа>.yml`, импорт плейбука в
`playbooks/site.yml`.
