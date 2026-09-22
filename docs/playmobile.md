# Проект playmobile

App-узлы проекта: RHEL 10, Docker CE с корпоративного зеркала.

## Хосты

| Окружение | Хосты | Адреса |
|---|---|---|
| dev  | `playm-dev-app01` | 172.31.125.51 |
| test | `playm-tst-app01…04` | 172.31.125.151-154 |
| prod | `playm-prd-01…06` | 172.31.126.51-56 |

Группа в инвентори — `playmobile`, файл `inventories/<env>/integration.yml`.

## Запуск

```bash
make play ENV=dev  PLAYBOOK=playbooks/playmobile.yml CHECK=1
make play ENV=prod PLAYBOOK=playbooks/playmobile.yml LIMIT=playm-prd-01
```

Плейбук состоит из одной роли `docker` — базовую настройку ОС на этих
узлах делает команда инфраструктуры, поэтому роль `common` сюда не
подключена (см. раздел «Separation of duties» в README).

## Что делает роль

1. `/etc/yum.repos.d/docker-ce.repo` с
   `baseurl={{ docker_repo_baseurl }}` (по умолчанию
   `http://mirror.ipotekabank.uz/repos/docker/`) и `module_hotfixes=true`
   — без него `containerd.io` на RHEL не ставится.
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
* **GPG.** `docker_repo_gpgcheck: false` — на плоском зеркале обычно нет
  ключа. Включается вместе с `docker_repo_gpgkey`.
* **podman.** Удаление конфликтующих пакетов выключено
  (`docker_remove_conflicting_packages: false`). Включите, если на
  app-узлах podman не нужен.
* **Реестры.** `insecure-registries` перечислены по HTTP-имени Nexus;
  если появится TLS с корпоративным CA, правильнее убрать их отсюда и
  раскатать CA на узлы.
