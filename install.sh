#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_VERSION="1.0.2"
SCRIPT_PATH="/usr/local/sbin/safe-monthly-maintenance"
CONFIG_PATH="/etc/default/safe-monthly-maintenance"
SERVICE_PATH="/etc/systemd/system/safe-monthly-maintenance.service"
TIMER_PATH="/etc/systemd/system/safe-monthly-maintenance.timer"

usage() {
    cat <<'EOF'
Usage:
  sudo bash install-safe-monthly-maintenance.sh [--run-now]

Options:
  --run-now  Install timer, then run maintenance immediately.
  --help     Show help.
EOF
}

RUN_NOW=0
case "${1:-}" in
    "")
        ;;
    --run-now)
        RUN_NOW=1
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
esac

if (( EUID != 0 )); then
    echo "Run as root: sudo bash $0 ${1:-}" >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "Unsupported system: /etc/os-release missing" >&2
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
    ubuntu:*|debian:*|*:*debian*)
        ;;
    *)
        echo "Unsupported distribution: ${PRETTY_NAME:-unknown}. Ubuntu/Debian required." >&2
        exit 1
        ;;
esac

for command_name in apt-get dpkg systemctl systemd-analyze journalctl flock systemd-tmpfiles; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command missing: $command_name" >&2
        exit 1
    fi
done

work_dir="$(mktemp -d)"
cleanup() {
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

cat >"$work_dir/safe-monthly-maintenance" <<'MAINTENANCE_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

MAINTENANCE_VERSION="1.0.2"
CONFIG_PATH="/etc/default/safe-monthly-maintenance"
LOCK_PATH="/run/lock/safe-monthly-maintenance.lock"
BACKUP_DIR="/var/backups/safe-monthly-maintenance"

# Safe defaults. Override through /etc/default/safe-monthly-maintenance.
JOURNAL_MAX_AGE="30d"
JOURNAL_MAX_SIZE="500M"
MIN_ROOT_FREE_KB="1048576"
MIN_BOOT_FREE_KB="204800"
ENABLE_AUTOREMOVE="0"
ENABLE_DOCKER_PRUNE="0"

case "${1:-}" in
    "")
        ;;
    --help|-h)
        cat <<'EOF'
Safe monthly Ubuntu/Debian maintenance.

Configuration: /etc/default/safe-monthly-maintenance
Logs:          journalctl -u safe-monthly-maintenance.service

No automatic reboot. Autoremove and Docker prune are disabled by default.
EOF
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        exit 2
        ;;
esac

if [[ -r "$CONFIG_PATH" ]]; then
    # shellcheck disable=SC1090
    . "$CONFIG_PATH"
fi

log() {
    printf '[safe-maintenance] %s\n' "$*"
}

failures=()
run_step() {
    local label="$1"
    local rc
    shift
    log "START: $label"
    if "$@"; then
        log "OK: $label"
        return 0
    else
        rc=$?
        failures+=("$label (exit $rc)")
        log "ERROR: $label (exit $rc)"
        return "$rc"
    fi
}

if (( EUID != 0 )); then
    log "ERROR: root privileges required"
    exit 1
fi

exec 9>"$LOCK_PATH"
if ! flock -n 9; then
    log "Another maintenance run is active. Exiting."
    exit 0
fi

if [[ ! -r /etc/os-release ]]; then
    log "ERROR: /etc/os-release missing"
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
    ubuntu:*|debian:*|*:*debian*)
        ;;
    *)
        log "ERROR: unsupported distribution ${PRETTY_NAME:-unknown}"
        exit 1
        ;;
esac

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
# List services using old libraries; never restart every service automatically.
export NEEDRESTART_MODE=l

APT_OPTIONS=(
    -o Dpkg::Lock::Timeout=600
    -o Acquire::Retries=3
)

log "Version $MAINTENANCE_VERSION"
log "System: ${PRETTY_NAME:-unknown}"
log "Started: $(date --iso-8601=seconds)"

install -d -m 0750 "$BACKUP_DIR"
snapshot_path="$BACKUP_DIR/dpkg-selections-$(date +%Y%m%d-%H%M%S).txt"
if dpkg --get-selections >"$snapshot_path"; then
    log "Package selection snapshot: $snapshot_path"
else
    failures+=("package selection snapshot")
    rm -f -- "$snapshot_path"
fi
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'dpkg-selections-*.txt' -mtime +120 -delete

# Use system policies for temporary files and logs. No manual rm in /tmp or /var/log.
run_step "systemd temporary-file cleanup" systemd-tmpfiles --clean || true
if command -v logrotate >/dev/null 2>&1; then
    run_step "scheduled log rotation" logrotate /etc/logrotate.conf || true
fi
run_step "journal rotation" journalctl --rotate || true
run_step "journal age cleanup" journalctl "--vacuum-time=$JOURNAL_MAX_AGE" || true
run_step "journal size cleanup" journalctl "--vacuum-size=$JOURNAL_MAX_SIZE" || true

if ! dpkg_audit="$(dpkg --audit 2>&1)"; then
    failures+=("dpkg audit command")
    log "ERROR: dpkg audit failed: $dpkg_audit"
    apt_ready=0
elif [[ -n "$dpkg_audit" ]]; then
    failures+=("dpkg state incomplete")
    log "ERROR: interrupted/incomplete package state detected:"
    printf '%s\n' "$dpkg_audit"
    log "APT upgrade skipped. Repair manually with: dpkg --configure -a"
    apt_ready=0
else
    apt_ready=1
fi

run_step "APT autoclean" apt-get "${APT_OPTIONS[@]}" -y autoclean || true

if (( apt_ready == 1 )); then
    if run_step "APT metadata update" apt-get "${APT_OPTIONS[@]}" update; then
        root_free_kb="$(df -Pk / | awk 'NR == 2 {print $4}')"
        log "Root free space: ${root_free_kb} KiB"

        space_ok=1
        if (( root_free_kb < MIN_ROOT_FREE_KB )); then
            failures+=("insufficient root free space")
            log "ERROR: root free space below ${MIN_ROOT_FREE_KB} KiB; upgrade skipped"
            space_ok=0
        fi

        if mountpoint -q /boot; then
            boot_free_kb="$(df -Pk /boot | awk 'NR == 2 {print $4}')"
            log "/boot free space: ${boot_free_kb} KiB"
            if (( boot_free_kb < MIN_BOOT_FREE_KB )); then
                failures+=("insufficient /boot free space")
                log "ERROR: /boot free space below ${MIN_BOOT_FREE_KB} KiB; upgrade skipped"
                space_ok=0
            fi
        fi

        if (( space_ok == 1 )); then
            # Never use dist-upgrade/full-upgrade. Never remove packages.
            # --with-new-pkgs permits kernel/security dependencies without removals.
            run_step "safe package upgrade" \
                apt-get "${APT_OPTIONS[@]}" -y \
                -o Dpkg::Options::=--force-confold \
                --with-new-pkgs --no-remove upgrade || true
            run_step "APT consistency check" apt-get "${APT_OPTIONS[@]}" check || true
        fi
    else
        log "APT upgrade skipped because metadata update failed"
    fi
fi

if [[ "$ENABLE_AUTOREMOVE" == "1" ]]; then
    log "Autoremove explicitly enabled by config"
    run_step "APT autoremove" \
        apt-get "${APT_OPTIONS[@]}" -y --purge autoremove || true
else
    log "Autoremove disabled. Dry-run candidates:"
    apt-get "${APT_OPTIONS[@]}" --dry-run autoremove || true
fi

run_step "APT cache cleanup" apt-get "${APT_OPTIONS[@]}" clean || true

if [[ "$ENABLE_DOCKER_PRUNE" == "1" ]] && command -v docker >/dev/null 2>&1; then
    log "Docker dangling-image prune explicitly enabled by config"
    run_step "Docker dangling-image prune" docker image prune -f || true
else
    log "Docker prune disabled"
fi

reboot_required=0
if [[ -e /var/run/reboot-required ]]; then
    reboot_required=1
fi

running_kernel="$(uname -r)"
latest_kernel=""
if [[ -e /vmlinuz ]]; then
    latest_kernel="$(basename "$(readlink -f /vmlinuz)")"
    latest_kernel="${latest_kernel#vmlinuz-}"
fi
if [[ -n "$latest_kernel" && "$latest_kernel" != "$running_kernel" ]]; then
    reboot_required=1
    log "Installed kernel differs from running kernel: $running_kernel -> $latest_kernel"
fi

if (( reboot_required == 1 )); then
    log "REBOOT REQUIRED. Automatic reboot disabled."
    if [[ -r /var/run/reboot-required.pkgs ]]; then
        sed 's/^/[safe-maintenance] reboot package: /' /var/run/reboot-required.pkgs
    fi
else
    log "Reboot not required"
fi

log "Failed systemd units:"
systemctl --failed --no-pager || true
log "Disk usage:"
df -h / /boot 2>/dev/null | awk '!seen[$1]++' || true
log "Finished: $(date --iso-8601=seconds)"

if (( ${#failures[@]} > 0 )); then
    log "Completed with ${#failures[@]} warning/error(s):"
    printf '[safe-maintenance] - %s\n' "${failures[@]}"
    exit 1
fi

log "Completed successfully"
MAINTENANCE_SCRIPT

cat >"$work_dir/safe-monthly-maintenance.default" <<'MAINTENANCE_CONFIG'
# Safe defaults. Set to 1 only after reviewing each VM.
ENABLE_AUTOREMOVE=0
ENABLE_DOCKER_PRUNE=0

# Journal retention limits.
JOURNAL_MAX_AGE=30d
JOURNAL_MAX_SIZE=500M

# Skip package upgrade below these free-space thresholds.
MIN_ROOT_FREE_KB=1048576
MIN_BOOT_FREE_KB=204800
MAINTENANCE_CONFIG

cat >"$work_dir/safe-monthly-maintenance.service" <<'SERVICE_UNIT'
[Unit]
Description=Safe monthly Ubuntu/Debian maintenance
Documentation=man:apt-get(8)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/safe-monthly-maintenance
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=2h
SERVICE_UNIT

cat >"$work_dir/safe-monthly-maintenance.timer" <<'TIMER_UNIT'
[Unit]
Description=Run safe monthly Ubuntu/Debian maintenance

[Timer]
OnCalendar=*-*-01 03:00:00
RandomizedDelaySec=6h
Persistent=true
AccuracySec=15m
Unit=safe-monthly-maintenance.service

[Install]
WantedBy=timers.target
TIMER_UNIT

bash -n "$work_dir/safe-monthly-maintenance"
install -m 0755 "$work_dir/safe-monthly-maintenance" "$SCRIPT_PATH"
systemd-analyze verify \
    "$work_dir/safe-monthly-maintenance.service" \
    "$work_dir/safe-monthly-maintenance.timer"

if [[ ! -e "$CONFIG_PATH" ]]; then
    install -m 0644 "$work_dir/safe-monthly-maintenance.default" "$CONFIG_PATH"
else
    echo "Preserving existing config: $CONFIG_PATH"
fi
install -m 0644 "$work_dir/safe-monthly-maintenance.service" "$SERVICE_PATH"
install -m 0644 "$work_dir/safe-monthly-maintenance.timer" "$TIMER_PATH"

systemctl daemon-reload
systemctl enable --now safe-monthly-maintenance.timer

echo "Installed safe monthly maintenance v$INSTALLER_VERSION"
systemctl list-timers safe-monthly-maintenance.timer --all --no-pager
echo "Config: $CONFIG_PATH"
echo "Logs: journalctl -u safe-monthly-maintenance.service"

if (( RUN_NOW == 1 )); then
    echo "Running maintenance now..."
    systemctl reset-failed safe-monthly-maintenance.service 2>/dev/null || true
    systemctl start safe-monthly-maintenance.service
    systemctl status safe-monthly-maintenance.service --no-pager -l
fi
