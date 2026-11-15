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
from .settings import DATA_DIR, atomic_write_text, settings

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

    MAX_POINTS = 100_000  # 筆數保險上限：更新間隔設很短時 (最短 30 秒) 最近 30 天的完整資料也可能很多

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
        self._read_only = False  # 讀不到或無法另存原檔時不寫入，避免蓋掉使用者的歷史
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
        self._compact_and_save()

    def replace_all(self, points: List[HistoryPoint]) -> None:
        """用裝置內存的紀錄補空白後整批寫回。"""
        self.points = list(points)
        self._compact_and_save()

    def _now(self) -> float:
        return time.time()

    def _compact_and_save(self) -> None:
        """依保存天數清掉過期資料、超過 30 天的合併成每小時一筆，再寫檔。"""
        from . import device_history  # device_history 也引用本模組的 HistoryPoint，避免循環 import
        retention = device_history.retention_days(settings.get(device_history.RETENTION_KEY))
        self.points = device_history.compact(self.points, self._now(), retention)
        if len(self.points) > self.MAX_POINTS:
            del self.points[:len(self.points) - self.MAX_POINTS]
        self._save()

    def _save(self) -> None:
        if self._read_only:
            return
        try:
            atomic_write_text(self.storage_path, json.dumps([asdict(p) for p in self.points]))
        except OSError as e:
            mijia_log(f"無法寫入歷史檔 {self.storage_path.name}: {e}")

    def _load(self) -> None:
        try:
            raw = self.storage_path.read_bytes()
        except FileNotFoundError:
            return
        except OSError as e:
            self._read_only = True
            mijia_log(f"無法讀取歷史檔 {self.storage_path.name}，本次不寫入: {e}")
            return
        try:
            # 解碼失敗 (UnicodeDecodeError) 也屬於 ValueError，一併當成損毀
            self.points = [HistoryPoint(**item) for item in json.loads(raw.decode("utf-8"))]
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
            self._read_only = True
            mijia_log(f"歷史檔損毀且無法另存，本次不寫入: {e}")

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
