#!/bin/bash
set -euo pipefail

# Post-deploy hook: reload systemd user services after dotter deploy.
systemctl --user daemon-reload

sync_path_unit="nowledge-mem-certifi-sync.path"
sync_service_unit="nowledge-mem-certifi-sync.service"
sync_path_file="$HOME/.config/systemd/user/${sync_path_unit}"
sync_service_file="$HOME/.config/systemd/user/${sync_service_unit}"

if [[ -f "$sync_path_file" ]]; then
    systemctl --user enable --now "$sync_path_unit"
fi

if [[ -f "$sync_service_file" ]]; then
    systemctl --user enable "$sync_service_unit"

    if systemctl --user is-active --quiet nowledge-mem.service; then
        systemctl --user start "$sync_service_unit"
    fi
fi

update_timer_unit="nowledge-mem-check-update.timer"
update_timer_file="$HOME/.config/systemd/user/${update_timer_unit}"

if [[ -f "$update_timer_file" ]]; then
    systemctl --user enable --now "$update_timer_unit"
fi
