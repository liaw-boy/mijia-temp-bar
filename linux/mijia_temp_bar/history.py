"""歷史採樣點保存 (每台裝置一個檔：~/.local/share/mijia-temp-bar/history/<裝置>.json) 與 CSV 匯出。"""

import csv
import json
import time
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import ClassVar, Dict, List, Optional

from .devices import copy_without_overwrite, history_path_for
from .logger import mijia_log
from .settings import DATA_DIR, atomic_write_text

HISTORY_DIR = DATA_DIR / "history"
LEGACY_HISTORY_PATH = DATA_DIR / "history.json"  # 舊版單一裝置的歷史檔 (只讀取來遷移，不再寫入)


@dataclass(frozen=True)
class HistoryPoint:
    timestamp: float  # Unix time (秒)
    temperature: float
    humidity: float
    voltage: float
    batteryPercent: int


class HistoryManager:
    _by_path: ClassVar[Dict[Path, "HistoryManager"]] = {}

    MAX_POINTS = 8640  # 最多保留 30 天 (5 分鐘間隔 = 8640 筆)

    @classmethod
    def for_device(cls, device_id: str, base: Path = HISTORY_DIR) -> "HistoryManager":
        """同一台裝置共用同一個實例 (儀表板與狀態列看到的是同一份資料)。"""
        path = history_path_for(device_id, base)
        manager = cls._by_path.get(path)
        if manager is None:
            manager = cls(path)
            cls._by_path[path] = manager
        return manager

    def __init__(self, storage_path: Path):
        self.storage_path = storage_path
        self.points: List[HistoryPoint] = []
        self._load()

    @property
    def last_point(self) -> Optional[HistoryPoint]:
        return self.points[-1] if self.points else None

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
        except OSError as e:
            mijia_log(f"無法寫入歷史檔 {self.storage_path.name}: {e}")

    def _load(self) -> None:
        try:
            text = self.storage_path.read_text(encoding="utf-8")
        except OSError:
            self.points = []
            return
        try:
            self.points = [HistoryPoint(**item) for item in json.loads(text)]
        except (ValueError, TypeError):
            self.points = []
            self._set_aside_corrupted()

    def _set_aside_corrupted(self) -> None:
        """損毀的檔案先另存一份，避免下次寫入時被默默覆蓋。"""
        backup = self.storage_path.with_name(f"{self.storage_path.stem}.corrupt-{int(time.time())}.json")
        try:
            copy_without_overwrite(self.storage_path, backup)
            mijia_log(f"歷史檔損毀，已另存為 {backup.name}")
        except OSError as e:
            mijia_log(f"歷史檔損毀且無法另存: {e}")

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
