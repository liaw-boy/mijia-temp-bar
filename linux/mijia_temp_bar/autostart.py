"""開機自動啟動 (XDG Autostart：~/.config/autostart/mijia-temp-bar.desktop)。"""

import re
import shutil
import sys
from pathlib import Path

from .settings import APP_DIR_NAME, xdg_dir

AUTOSTART_PATH = xdg_dir("XDG_CONFIG_HOME", ".config") / "autostart" / f"{APP_DIR_NAME}.desktop"


def _exec_quote(arg: str) -> str:
    """依 Desktop Entry 規範為 Exec 參數加上引號。"""
    arg = arg.replace("%", "%%")
    if re.fullmatch(r"[\w@%+=:,./-]+", arg):
        return arg
    escaped = re.sub(r'(["`$\\])', r"\\\1", arg)
    return '"' + escaped.replace("\\", "\\\\") + '"'


def launch_command() -> str:
    launcher = shutil.which(APP_DIR_NAME)
    if launcher:
        return _exec_quote(launcher)
    # 直接從原始碼目錄執行時
    package_parent = str(Path(__file__).resolve().parent.parent)
    return " ".join(_exec_quote(a) for a in ("env", f"PYTHONPATH={package_parent}", sys.executable, "-m", "mijia_temp_bar"))


def is_enabled() -> bool:
    return AUTOSTART_PATH.exists()


def set_enabled(enabled: bool) -> None:
    if not enabled:
        AUTOSTART_PATH.unlink(missing_ok=True)
        return
    AUTOSTART_PATH.parent.mkdir(parents=True, exist_ok=True)
    AUTOSTART_PATH.write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=MijiaTempBar\n"
        "Name[zh_TW]=米家溫濕度狀態列\n"
        "Comment=米家藍牙溫濕度計 2 (LYWSD03MMC) 系統匣監控\n"
        f"Exec={launch_command()}\n"
        f"Icon={APP_DIR_NAME}\n"
        "Terminal=false\n"
        "X-GNOME-Autostart-enabled=true\n",
        encoding="utf-8",
    )
