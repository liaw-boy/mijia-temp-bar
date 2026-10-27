#!/usr/bin/env bash
# 移除 MijiaTempBar Linux 版。加上 --purge 會一併刪除歷史數據、設定與日誌。
set -euo pipefail

APP="mijia-temp-bar"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

pkill -f "$HOME/.local/lib/$APP/venv/bin/python" 2>/dev/null || true

rm -rf "$HOME/.local/lib/$APP"
rm -f "$HOME/.local/bin/$APP"
rm -f "$DATA_HOME/applications/$APP.desktop"
rm -f "$DATA_HOME/icons/hicolor/256x256/apps/$APP.png"
rm -f "$CONFIG_HOME/autostart/$APP.desktop"
update-desktop-database "$DATA_HOME/applications" >/dev/null 2>&1 || true

if [ "${1:-}" = "--purge" ]; then
    rm -rf "$DATA_HOME/$APP" "$CONFIG_HOME/$APP" "$STATE_HOME/$APP"
    echo "==> 已移除 MijiaTempBar 以及所有歷史數據與設定。"
else
    echo "==> 已移除 MijiaTempBar (歷史數據保留於 $DATA_HOME/$APP，加上 --purge 可一併刪除)。"
fi
