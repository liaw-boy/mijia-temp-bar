"""設定選項與輸入驗證 (純邏輯，不依賴 GTK，可單元測試)。"""

import math
from enum import IntEnum
from typing import List, Optional, Tuple


class DisplayStyle(IntEnum):
    STATS_BADGE = 0  # 雙行微型膠囊風格 (TMP / HUM 雙行對齊)
    STACKED = 1      # 純數字雙行堆疊 (26.1° / 63%)
    HORIZONTAL = 2   # 橫向完整 (26.1°C  65%)
    TEMP_ONLY = 3    # 僅溫度 (26.1°C)
    COMPACT = 4      # 緊湊單行 (26.1° 65%)


STYLE_TITLES: List[Tuple[DisplayStyle, str]] = [
    (DisplayStyle.STATS_BADGE, "雙行膠囊 (TMP / HUM)"),
    (DisplayStyle.STACKED, "純數字雙行 (26.1° / 63%)"),
    (DisplayStyle.HORIZONTAL, "橫向完整 (26°C  65%)"),
    (DisplayStyle.TEMP_ONLY, "僅溫度 (26°C)"),
    (DisplayStyle.COMPACT, "緊湊單行 (26.1° 65%)"),
]

INTERVALS: List[Tuple[str, float]] = [
    ("30 秒", 30.0),
    ("1 分鐘", 60.0),
    ("3 分鐘", 180.0),
    ("5 分鐘 (預設)", 300.0),
    ("10 分鐘", 600.0),
    ("15 分鐘", 900.0),
    ("30 分鐘", 1800.0),
    ("1 小時", 3600.0),
    ("2 小時", 7200.0),
]

# 圖表時間範圍：(標籤, 秒數；None 表示全部)
CHART_RANGES: List[Tuple[str, Optional[float]]] = [
    ("6 小時", 6 * 3600.0),
    ("24 小時", 24 * 3600.0),
    ("7 天", 7 * 86400.0),
    ("全部", None),
]
DEFAULT_CHART_RANGE_INDEX = 1

MIN_INTERVAL_MINUTES = 0.5
MAX_INTERVAL_MINUTES = 1440.0


def parse_interval_minutes(text: str) -> Optional[float]:
    """把使用者輸入的分鐘數轉成秒；無效 (非數字、NaN、超出 0.5~1440 分鐘) 回傳 None。"""
    try:
        minutes = float(text.strip())
    except ValueError:
        return None
    if not math.isfinite(minutes) or not (MIN_INTERVAL_MINUTES <= minutes <= MAX_INTERVAL_MINUTES):
        return None
    return minutes * 60.0


def describe_interval(seconds: float) -> str:
    """自訂間隔的顯示文字 (1 小時以上用小時)。"""
    if seconds >= 3600.0:
        hours = seconds / 3600.0
        return f"{hours:.0f} 小時" if hours.is_integer() else f"{hours:.1f} 小時"
    return f"{round(seconds / 60.0)} 分鐘"
