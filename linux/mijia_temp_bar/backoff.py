"""離線指數退避策略 (純函式，不依賴藍牙堆疊)。"""

RETRY_AFTER_FAILURE = 60.0  # 連線失敗後最快多久重試 (不超過使用者設定的間隔)


def retry_delay(failures: int, interval: float) -> float:
    """1~2 次快速重試、3~4 次退到 5 分鐘、之後 15 分鐘 (皆不短於使用者間隔)。"""
    if failures <= 2:
        return min(interval, RETRY_AFTER_FAILURE)
    if failures <= 4:
        return max(interval, 300.0)
    return max(interval, 900.0)
