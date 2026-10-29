#!/usr/bin/env bash
# MijiaTempBar Linux 版安裝腳本：安裝到目前使用者的 ~/.local，不需要 root 權限
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT="$(cd .. && pwd)"

APP="mijia-temp-bar"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
LIB_DIR="$HOME/.local/lib/$APP"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$DATA_HOME/applications"
ICON_ROOT="$DATA_HOME/icons/hicolor"

# PyGObject (gi) 通常只裝在系統 Python，conda / pyenv 的 Python 會找不到
PYTHON="${PYTHON:-}"
if [ -z "$PYTHON" ]; then
    if [ -x /usr/bin/python3 ]; then PYTHON=/usr/bin/python3; else PYTHON="$(command -v python3)"; fi
fi

print_deps_hint() {
    cat <<'EOF'
請先安裝系統套件：
  Ubuntu / Debian : sudo apt install python3-venv python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 bluez
  Fedora          : sudo dnf install python3-gobject python3-cairo gtk3 libayatana-appindicator-gtk3 bluez
  Arch Linux      : sudo pacman -S python-gobject python-cairo gtk3 libayatana-appindicator bluez
EOF
}

echo "==> 檢查系統相依套件 ($PYTHON)..."
if ! "$PYTHON" - <<'EOF'
import sys
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gtk, PangoCairo  # noqa: F401
import cairo  # noqa: F401
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
except ValueError:
    gi.require_version("AppIndicator3", "0.1")
if sys.version_info < (3, 10):
    sys.exit("需要 Python 3.10 以上版本")
EOF
then
    print_deps_hint
    exit 1
fi
if ! "$PYTHON" -c "import venv, ensurepip" 2>/dev/null; then
    echo "找不到 Python venv 模組。"
    print_deps_hint
    exit 1
fi

echo "==> 建立虛擬環境並安裝 bleak..."
mkdir -p "$LIB_DIR"
"$PYTHON" -m venv --system-site-packages "$LIB_DIR/venv"
"$LIB_DIR/venv/bin/python" -m pip install --quiet --upgrade pip
"$LIB_DIR/venv/bin/python" -m pip install --quiet -r requirements.txt

echo "==> 複製程式檔案到 $LIB_DIR..."
rm -rf "$LIB_DIR/mijia_temp_bar"
cp -r mijia_temp_bar "$LIB_DIR/"
find "$LIB_DIR/mijia_temp_bar" -name "__pycache__" -type d -prune -exec rm -rf {} +

echo "==> 建立啟動指令 $BIN_DIR/$APP..."
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/$APP" <<EOF
#!/bin/sh
export PYTHONPATH="$LIB_DIR\${PYTHONPATH:+:\$PYTHONPATH}"
exec "$LIB_DIR/venv/bin/python" -m mijia_temp_bar "\$@"
EOF
chmod +x "$BIN_DIR/$APP"

echo "==> 產生 App 圖示與應用程式選單項目..."
"$LIB_DIR/venv/bin/python" -c "
import sys
sys.path.insert(0, sys.argv[1])
from mijia_temp_bar.icons import save_app_icon
save_app_icon(sys.argv[2], 256)
" "$LIB_DIR" "$ICON_ROOT/256x256/apps/$APP.png"
gtk-update-icon-cache --force --ignore-theme-index "$ICON_ROOT" >/dev/null 2>&1 || true

mkdir -p "$APPS_DIR"
cat > "$APPS_DIR/$APP.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=MijiaTempBar
Name[zh_TW]=米家溫濕度狀態列
GenericName=Temperature & Humidity Monitor
GenericName[zh_TW]=溫濕度監控
Comment=Xiaomi Mijia LYWSD03MMC temperature & humidity monitor in the system tray
Comment[zh_TW]=米家藍牙溫濕度計 2 (LYWSD03MMC) 系統匣監控
Exec="$BIN_DIR/$APP"
Icon=$APP
Terminal=false
Categories=Utility;System;Monitor;
Keywords=xiaomi;mijia;thermometer;humidity;bluetooth;LYWSD03MMC;
StartupWMClass=$APP
StartupNotify=false
EOF
update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true

echo "==> 安裝完成！"
echo "    從應用程式選單開啟「米家溫濕度狀態列」，或在終端機執行: $APP"
echo "    開機自動啟動可在系統匣選單中勾選「開機時自動啟動」。"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "    提示: $BIN_DIR 不在 PATH 中，請使用完整路徑 $BIN_DIR/$APP 執行。" ;;
esac

# 系統匣圖示需要桌面環境提供 StatusNotifier 服務 (KDE 內建；GNOME 需要 AppIndicator 擴充套件)
if command -v gdbus >/dev/null 2>&1; then
    watcher="$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.NameHasOwner org.kde.StatusNotifierWatcher 2>/dev/null || true)"
    if [[ "$watcher" != *true* ]]; then
        echo "    注意: 目前桌面沒有系統匣 (StatusNotifier) 服務，圖示將無法顯示。"
        echo "          GNOME 請安裝並啟用 AppIndicator 擴充套件 (Ubuntu 預設已啟用；其他發行版套件名稱為"
        echo "          gnome-shell-extension-appindicator)。"
    fi
fi
