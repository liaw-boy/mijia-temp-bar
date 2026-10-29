"""版本更新檢查：查詢 GitHub releases，只比對 linux-v 前綴的版本 (與 macOS 版本號分開)。

只提示、不自動安裝。解析與比對為純函式，網路請求在背景執行緒進行。
"""

import http.client
import json
import math
import threading
import time
import urllib.error
import urllib.request
from typing import Callable, NamedTuple, Optional, Tuple
from urllib.parse import urlparse

from . import __version__
from .settings import settings

REPO = "liaw-boy/mijia-temp-bar"
TAG_PREFIX = "linux-v"
API_URL = f"https://api.github.com/repos/{REPO}/releases?per_page=30"
CHECK_INTERVAL = 24 * 3600
AUTO_KEY = "AutoCheckUpdates"
LAST_KEY = "LastUpdateCheckTime"
MAX_RESPONSE_BYTES = 1_000_000


class UpdateResult(NamedTuple):
    kind: str                # "up_to_date" | "available" | "failed"
    message: str
    version: Optional[str] = None
    url: Optional[str] = None


def parse_version(text: str) -> Tuple[int, ...]:
    """'1.10.0' -> (1, 10, 0)；每段只取開頭的數字，無法解析視為 0。"""
    parts = []
    for part in text.strip().split("."):
        digits = ""
        for ch in part:
            if ch not in "0123456789":
                break
            digits += ch
        parts.append(int(digits) if digits else 0)
    return tuple(parts)


def is_newer(candidate: str, current: str) -> bool:
    a, b = parse_version(candidate), parse_version(current)
    size = max(len(a), len(b))
    return a + (0,) * (size - len(a)) > b + (0,) * (size - len(b))


def is_trusted_release_url(url: str) -> bool:
    """只接受本專案 GitHub 頁面 (https)，避免被導向其他網址。"""
    parsed = urlparse(url)
    return parsed.scheme == "https" and parsed.hostname == "github.com" and parsed.path.startswith(f"/{REPO}/releases/")


def pick_latest(releases, current: str) -> UpdateResult:
    """從 releases 清單挑出 linux-v 前綴中最新的一筆並與目前版本比對。"""
    best: Optional[Tuple[Tuple[int, ...], str, str]] = None
    if not isinstance(releases, list):
        return UpdateResult("failed", "版本資訊格式不正確")
    for item in releases:
        if not isinstance(item, dict) or item.get("draft") or item.get("prerelease"):
            continue
        tag, url = item.get("tag_name"), item.get("html_url")
        if not isinstance(tag, str) or not isinstance(url, str) or not tag.startswith(TAG_PREFIX):
            continue
        if not is_trusted_release_url(url):
            continue
        version = tag[len(TAG_PREFIX):]
        key = parse_version(version)
        if best is None or key > best[0]:
            best = (key, version, url)
    if best is None or not is_newer(best[1], current):
        return UpdateResult("up_to_date", f"已是最新版本 ({current})。", version=current)
    return UpdateResult("available", f"有新版本 {best[1]}，請前往 GitHub 下載。", version=best[1], url=best[2])


def fetch_and_check(current: str = __version__) -> UpdateResult:
    request = urllib.request.Request(API_URL, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": f"MijiaTempBar-Linux/{current}",
    })
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            body = response.read(MAX_RESPONSE_BYTES + 1)
        if len(body) > MAX_RESPONSE_BYTES:
            return UpdateResult("failed", "版本資訊過大")
        return pick_latest(json.loads(body.decode("utf-8")), current)
    except (urllib.error.URLError, http.client.HTTPException, OSError):
        return UpdateResult("failed", "無法連線，請檢查網路")
    except (ValueError, RecursionError):
        return UpdateResult("failed", "版本資訊格式不正確")


def auto_check_enabled() -> bool:
    value = settings.get(AUTO_KEY)
    return value if isinstance(value, bool) else True


def set_auto_check(enabled: bool) -> None:
    settings.set(AUTO_KEY, enabled)


def due_for_auto_check(now: float) -> bool:
    if not auto_check_enabled():
        return False
    last = settings.get(LAST_KEY)
    valid = isinstance(last, (int, float)) and not isinstance(last, bool) and math.isfinite(last)
    return not (valid and 0 <= now - last < CHECK_INTERVAL)


def check_async(on_result: Callable[[UpdateResult], None], dispatch: Callable[..., None]) -> None:
    """背景執行檢查，結果透過 dispatch 回到主執行緒；失敗不更新上次檢查時間。"""
    def worker() -> None:
        try:
            result = fetch_and_check()
        except Exception:  # 任何意外都要回報，避免介面卡在「檢查中」
            result = UpdateResult("failed", "檢查失敗")
        if result.kind != "failed":
            settings.set(LAST_KEY, time.time())
        dispatch(on_result, result)
    threading.Thread(target=worker, name="mijia-update-check", daemon=True).start()
