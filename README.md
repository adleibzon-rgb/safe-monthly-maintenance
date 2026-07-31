# Safe Monthly Maintenance

Безопасное ежемесячное обслуживание Ubuntu/Debian одной командой.

Скрипт устанавливает systemd timer, обновляет пакеты без `dist-upgrade`, чистит
безопасные кэши и журналы, проверяет состояние `dpkg`, свободное место и
необходимость перезагрузки. Автоматическая перезагрузка, `autoremove` и очистка
Docker выключены по умолчанию.

> Проверено на Debian 12. Скрипт рассчитан на Ubuntu и Debian с systemd и APT.
> Перед массовым развертыванием проверьте его на одной тестовой VM.

## Установка одной командой

Закрепленная версия:

```bash
curl -fsSL https://raw.githubusercontent.com/andrey271192/safe-monthly-maintenance/v1.0.2/install.sh | sudo bash -s -- --run-now
```

Команда:

1. скачивает `install.sh`;
2. устанавливает maintenance-скрипт и systemd units;
3. включает ежемесячный timer;
4. сразу выполняет первое обслуживание.

Установка без немедленного запуска:

```bash
curl -fsSL https://raw.githubusercontent.com/andrey271192/safe-monthly-maintenance/v1.0.2/install.sh | sudo bash
```

Если `curl` отсутствует:

```bash
wget -qO- https://raw.githubusercontent.com/andrey271192/safe-monthly-maintenance/v1.0.2/install.sh | sudo bash -s -- --run-now
```

## Более безопасная установка с проверкой

Не запускайте неизвестный код от `root` вслепую. Скачайте, проверьте, затем
выполните:

```bash
curl -fsSL https://raw.githubusercontent.com/andrey271192/safe-monthly-maintenance/v1.0.2/install.sh -o /tmp/install-safe-maintenance.sh
sha256sum /tmp/install-safe-maintenance.sh
less /tmp/install-safe-maintenance.sh
sudo bash /tmp/install-safe-maintenance.sh --run-now
```

SHA-256 версии `v1.0.2`:

```text
247312aaca5eb5b40c8893edb065203b2e4f0121c47421d85b46f9ae46770367
```

## Что устанавливается

| Путь | Назначение |
|---|---|
| `/usr/local/sbin/safe-monthly-maintenance` | Основной maintenance-скрипт |
| `/etc/default/safe-monthly-maintenance` | Настройки конкретной VM |
| `/etc/systemd/system/safe-monthly-maintenance.service` | Одноразовый systemd service |
| `/etc/systemd/system/safe-monthly-maintenance.timer` | Ежемесячный запуск |
| `/var/backups/safe-monthly-maintenance/` | Снимки списка пакетов |

Повторный запуск installer обновляет скрипт и units, но сохраняет существующий
файл настроек.

## Расписание

Timer запускается первого числа каждого месяца в 03:00 с случайной задержкой до
шести часов:

```ini
OnCalendar=*-*-01 03:00:00
RandomizedDelaySec=6h
Persistent=true
```

Случайная задержка уменьшает одновременную нагрузку на репозитории, если один
installer установлен на много VM. `Persistent=true` выполняет пропущенный запуск
после включения сервера.

## Что делает обслуживание

### 1. Проверяет окружение

- требует права `root`;
- разрешает только Ubuntu/Debian и Debian-подобные системы;
- использует `flock`, поэтому два запуска не идут одновременно;
- использует ожидание APT-lock до 600 секунд;
- повторяет сетевые обращения APT до трех раз.

### 2. Сохраняет список пакетов

Перед обновлением выполняется:

```bash
dpkg --get-selections
```

Снимок записывается в `/var/backups/safe-monthly-maintenance/`. Снимки старше
120 дней удаляются. Это не полный rollback системы, но помогает восстановить
состав пакетов.

### 3. Чистит только безопасные данные

- `systemd-tmpfiles --clean` — применяет штатные политики очистки временных
  файлов;
- `logrotate` — запускает штатную ротацию логов;
- `journalctl --vacuum-time=30d` — удаляет старый journal;
- `journalctl --vacuum-size=500M` — ограничивает размер journal;
- `apt-get autoclean` — удаляет устаревшие package-файлы;
- `apt-get clean` — очищает скачанный APT-кэш после обновления.

Скрипт не выполняет ручной `rm -rf` для `/tmp`, `/var/log`, Docker volumes или
пользовательских каталогов.

### 4. Проверяет пакетную систему

`dpkg --audit` запускается до обновления. Если пакетная операция была прервана,
обновление пропускается. Скрипт не пытается автоматически ремонтировать
неоднозначное состояние.

После обновления выполняется:

```bash
apt-get check
```

### 5. Проверяет свободное место

Обновление пропускается, если:

- на `/` осталось меньше 1 ГиБ;
- на отдельном `/boot` осталось меньше 200 МиБ.

Порог можно изменить в конфигурации.

### 6. Обновляет пакеты

Используется:

```bash
apt-get -y \
  -o Dpkg::Options::=--force-confold \
  --with-new-pkgs \
  --no-remove \
  upgrade
```

Почему:

- `upgrade`, не `dist-upgrade`/`full-upgrade`: пакеты не удаляются;
- `--with-new-pkgs`: разрешает новые зависимости, включая новое ядро;
- `--no-remove`: аварийно останавливает операцию, если APT захочет удалить
  пакет;
- `--force-confold`: сохраняет локальные конфиги вместо тихой замены;
- `NEEDRESTART_MODE=l`: показывает сервисы со старыми библиотеками, но не
  перезапускает все сервисы автоматически.

Пакетные maintainer scripts все равно могут перезапустить собственный сервис.
Абсолютно гарантировать отсутствие краткого service interruption при системном
обновлении невозможно.

### 7. Не удаляет зависимости автоматически

По умолчанию выполняется только dry-run:

```bash
apt-get --dry-run autoremove
```

Кандидаты попадают в журнал. Реальный `autoremove` включается только вручную
через конфигурацию.

### 8. Не перезагружает сервер

Скрипт проверяет `/var/run/reboot-required` и сравнивает текущее ядро с
`/vmlinuz`. При необходимости пишет:

```text
REBOOT REQUIRED. Automatic reboot disabled.
```

Решение о reboot остается у администратора.

### 9. Показывает итог

В конце журнал содержит:

- failed systemd units;
- использование диска;
- необходимость reboot;
- успешные и неуспешные этапы.

## Настройка

Файл:

```bash
sudo nano /etc/default/safe-monthly-maintenance
```

Параметры:

| Параметр | По умолчанию | Значение |
|---|---:|---|
| `ENABLE_AUTOREMOVE` | `0` | `1` разрешает `apt-get autoremove --purge` |
| `ENABLE_DOCKER_PRUNE` | `0` | `1` удаляет только dangling Docker images |
| `JOURNAL_MAX_AGE` | `30d` | Максимальный возраст systemd journal |
| `JOURNAL_MAX_SIZE` | `500M` | Максимальный размер journal |
| `MIN_ROOT_FREE_KB` | `1048576` | Минимум свободного места на `/` |
| `MIN_BOOT_FREE_KB` | `204800` | Минимум на отдельном `/boot` |

Для серверов с важными stopped-контейнерами и локальными Docker-образами
оставляйте `ENABLE_DOCKER_PRUNE=0`.

## Управление

Следующий запуск:

```bash
systemctl list-timers safe-monthly-maintenance.timer --all
```

Запустить вручную:

```bash
sudo systemctl start safe-monthly-maintenance.service
```

Последний статус:

```bash
systemctl status safe-monthly-maintenance.service
```

Логи:

```bash
journalctl -u safe-monthly-maintenance.service
```

Логи текущего запуска:

```bash
journalctl -u safe-monthly-maintenance.service --since today
```

Отключить автоматический запуск:

```bash
sudo systemctl disable --now safe-monthly-maintenance.timer
```

Удалить:

```bash
sudo systemctl disable --now safe-monthly-maintenance.timer
sudo rm -f /etc/systemd/system/safe-monthly-maintenance.timer
sudo rm -f /etc/systemd/system/safe-monthly-maintenance.service
sudo rm -f /usr/local/sbin/safe-monthly-maintenance
sudo systemctl daemon-reload
```

Конфигурация и package snapshots при удалении сохраняются намеренно.

## Массовое развертывание

Пример с локальным списком серверов:

```bash
for host in vm1.example.com vm2.example.com vm3.example.com; do
  ssh "$host" \
    'curl -fsSL https://raw.githubusercontent.com/andrey271192/safe-monthly-maintenance/v1.0.2/install.sh | sudo bash -s -- --run-now'
done
```

Сначала используйте одну тестовую VM. Для большой инфраструктуры лучше Ansible,
Salt или другой configuration-management инструмент.

## Ограничения

- Скрипт не делает filesystem/provider snapshot.
- Скрипт не исправляет сломанный `dpkg` автоматически.
- Скрипт не обновляет Ubuntu/Debian между major releases.
- Скрипт не управляет сторонними package managers.
- Скрипт не гарантирует отсутствие service restart от maintainer scripts.
- Скрипт не заменяет мониторинг, резервные копии и тестирование обновлений.

Подробная модель безопасности: [docs/SAFETY.md](docs/SAFETY.md).

## Лицензия

[MIT](LICENSE)
