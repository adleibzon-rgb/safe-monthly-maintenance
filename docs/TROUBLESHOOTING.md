# Диагностика

## Service завершился с ошибкой

```bash
systemctl status safe-monthly-maintenance.service
journalctl -u safe-monthly-maintenance.service -n 300 --no-pager
```

Скрипт продолжает независимые безопасные этапы и в конце возвращает ненулевой
код, если хотя бы один этап завершился ошибкой.

## APT занят

Скрипт ожидает lock до 600 секунд. Найдите владельца lock:

```bash
ps aux | grep -E 'apt|dpkg'
systemctl status apt-daily.service apt-daily-upgrade.service
```

Не удаляйте lock-файлы вручную, пока работает APT/DPKG.

## `dpkg --audit` показывает проблему

Проверьте вывод:

```bash
sudo dpkg --audit
```

Типовой ремонт:

```bash
sudo dpkg --configure -a
sudo apt-get -f install
```

Читайте список изменений перед подтверждением.

## Недостаточно места

```bash
df -h / /boot
du -xhd1 /var | sort -h
journalctl --disk-usage
```

Не уменьшайте защитный порог без понимания причины заполнения.

## Требуется reboot

```bash
uname -r
readlink -f /vmlinuz
cat /var/run/reboot-required 2>/dev/null
```

Перезагрузите в maintenance window:

```bash
sudo systemctl reboot
```

После reboot:

```bash
uname -r
systemctl --failed
```

## Timer не запускается

```bash
systemctl is-enabled safe-monthly-maintenance.timer
systemctl is-active safe-monthly-maintenance.timer
systemctl list-timers safe-monthly-maintenance.timer --all
```

Восстановить:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now safe-monthly-maintenance.timer
```
