#!/usr/bin/env bash
# install_pc_phone_automation.sh — Install user-level systemd automation for
# periodic phone sync. Runs as the current user (no sudo required).
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

mkdir -p "${_SYSTEMD_USER_DIR}"

cp "${_SCRIPT_DIR}/phone-auto-sync.service" "${_SYSTEMD_USER_DIR}/"
cp "${_SCRIPT_DIR}/phone-auto-sync.timer" "${_SYSTEMD_USER_DIR}/"

systemctl --user daemon-reload
systemctl --user enable --now phone-auto-sync.timer

printf 'Installed and enabled phone-auto-sync.timer\n'
printf 'Next run: '
systemctl --user list-timers phone-auto-sync.timer --no-legend | awk '{print $1, $2}' || \
    printf '(check with: systemctl --user list-timers)\n'
