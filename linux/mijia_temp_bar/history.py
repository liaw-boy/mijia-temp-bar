"""歷史採樣點保存 (~/.local/share/mijia-temp-bar/history.json) 與 CSV 匯出。"""

import csv
import json
import time
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import List, Optional

from .settings import DATA_DIR, atomic_write_text


@dataclass(frozen=True)
class HistoryPoint:
    timestamp: float  # Unix time (秒)
    temperature: float
    humidity: float
    voltage: float
    batteryPercent: int


class HistoryManager:
    _shared: Optional["HistoryManager"] = None

    MAX_POINTS = 8640  # 最多保留 30 天 (5 分鐘間隔 = 8640 筆)

    @classmethod
    def shared(cls) -> "HistoryManager":
        if cls._shared is None:
            cls._shared = cls()
        return cls._shared

    def __init__(self, storage_path: Path = DATA_DIR / "history.json"):
        self.storage_path = storage_path
        self.points: List[HistoryPoint] = []
        self._load()

    def add_point(self, temp: float, hum: float, volt: float, battery: int, timestamp: Optional[float] = None) -> None:
        self.points.append(HistoryPoint(
            timestamp=time.time() if timestamp is None else timestamp,
            temperature=temp,
            humidity=hum,
            voltage=volt,
            batteryPercent=battery,
        ))
        if len(self.points) > self.MAX_POINTS:
            del self.points[:len(self.points) - self.MAX_POINTS]
        self._save()

    def _save(self) -> None:
        try:
            atomic_write_text(self.storage_path, json.dumps([asdict(p) for p in self.points]))
        except OSError:
            pass

    def _load(self) -> None:
        try:
            raw = json.loads(self.storage_path.read_text(encoding="utf-8"))
            self.points = [HistoryPoint(**item) for item in raw]
        except (OSError, ValueError, TypeError):
            self.points = []

    # MARK: - 統計指標
    @property
    def min_temperature(self) -> Optional[float]:
        return min((p.temperature for p in self.points), default=None)

    @property
    def max_temperature(self) -> Optional[float]:
        return max((p.temperature for p in self.points), default=None)

    @property
    def min_humidity(self) -> Optional[float]:
        return min((p.humidity for p in self.points), default=None)

    @property
    def max_humidity(self) -> Optional[float]:
        return max((p.humidity for p in self.points), default=None)

    # MARK: - 匯出 CSV
    def export_csv(self, path: Path) -> None:
        with open(path, "w", encoding="utf-8", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["時間", "溫度 (°C)", "濕度 (%)", "電壓 (V)", "電量百分比 (%)"])
            for p in self.points:
                writer.writerow([
                    datetime.fromtimestamp(p.timestamp).strftime("%Y-%m-%d %H:%M:%S"),
                    f"{p.temperature:.2f}",
                    f"{p.humidity:.1f}",
                    f"{p.voltage:.3f}",
                    p.batteryPercent,
                ])
