"""偏好設定與 XDG 路徑 (對應 macOS 版的 UserDefaults)。"""

import json
import os
import tempfile
import threading
from pathlib import Path

APP_ID = "io.github.liaw_boy.MijiaTempBar"
APP_DIR_NAME = "mijia-temp-bar"


def xdg_dir(env: str, fallback: str) -> Path:
    value = os.environ.get(env)
    return Path(value) if value else Path.home() / fallback


CONFIG_DIR = xdg_dir("XDG_CONFIG_HOME", ".config") / APP_DIR_NAME
DATA_DIR = xdg_dir("XDG_DATA_HOME", ".local/share") / APP_DIR_NAME
STATE_DIR = xdg_dir("XDG_STATE_HOME", ".local/state") / APP_DIR_NAME
RUNTIME_DIR = Path(os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()) / APP_DIR_NAME


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class Settings:
    """以 JSON 檔保存的簡易鍵值設定，可跨執行緒讀寫。"""

    def __init__(self, path: Path = CONFIG_DIR / "settings.json"):
        self._path = path
        self._lock = threading.Lock()
        self._data: dict = {}
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                self._data = loaded
        except (OSError, ValueError):
            pass

    def get(self, key: str, default=None):
        with self._lock:
            return self._data.get(key, default)

    def set(self, key: str, value) -> None:
        with self._lock:
            self._data[key] = value
            text = json.dumps(self._data, ensure_ascii=False, indent=2)
        try:
            atomic_write_text(self._path, text)
        except OSError:
            pass


settings = Settings()
