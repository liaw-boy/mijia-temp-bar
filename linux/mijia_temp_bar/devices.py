"""多裝置清單：裝置模型、清單操作 (純函式)、舊版單一裝置設定的遷移與持久化。

遷移原則：只新增資料，絕不覆寫或刪除舊檔與舊設定鍵，裝回舊版仍可照常使用。
"""

import os
import re
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional, Sequence, Tuple

from .logger import mijia_log

KIND_STOCK = "stock"          # 原廠韌體：GATT 即連即斷讀取
KIND_BROADCAST = "broadcast"  # 開源韌體：解析廣播封包
KINDS = (KIND_STOCK, KIND_BROADCAST)
KIND_TITLES = {KIND_STOCK: "原廠直連", KIND_BROADCAST: "開源廣播"}

MAX_NAME_LENGTH = 24
DEFAULT_NAME_PREFIX = "溫濕度計"

DEVICES_KEY = "Devices"
PRIMARY_KEY = "PrimaryDeviceID"
LEGACY_TARGET_KEY = "TargetAddress"
LEGACY_UNCLAIMED_KEY = "LegacyHistoryUnclaimed"
LEGACY_LOW_BATTERY_KEY = "LastLowBatteryNotificationTime"
LOW_BATTERY_TIMES_KEY = "LowBatteryAlertTimes"
SETTINGS_BACKUP_NAME = "settings.pre-multidevice.json"

_MISSING = object()


@dataclass(frozen=True)
class Device:
    id: str     # 藍牙位址 (大寫，例如 A4:C1:38:8C:9B:32)
    name: str   # 使用者自訂名稱
    kind: str   # KIND_STOCK / KIND_BROADCAST

    def to_dict(self) -> dict:
        return {"id": self.id, "name": self.name, "kind": self.kind}


# MARK: - 純函式

def normalize_id(raw: str) -> str:
    return raw.strip().upper()


def file_id(device_id: str) -> str:
    """把裝置 id 轉成安全的檔名 (只留英數字，擋掉 ../ 等路徑字元)。"""
    safe = re.sub(r"[^A-Za-z0-9]", "", device_id)
    if not safe:
        raise ValueError(f"無法由裝置 id 產生檔名: {device_id!r}")
    return safe


def history_path_for(device_id: str, base: Path) -> Path:
    return base / f"{file_id(device_id)}.json"


def clean_name(name: str) -> str:
    """去掉前後空白；空白或超過長度限制時丟出 ValueError。"""
    cleaned = name.strip()
    if not cleaned:
        raise ValueError("名稱不可空白")
    if len(cleaned) > MAX_NAME_LENGTH:
        raise ValueError(f"名稱最多 {MAX_NAME_LENGTH} 個字")
    return cleaned


def default_name(existing: Sequence[Device]) -> str:
    """「溫濕度計 N」，N 取最小的未使用編號。"""
    used = {d.name for d in existing}
    n = 1
    while f"{DEFAULT_NAME_PREFIX} {n}" in used:
        n += 1
    return f"{DEFAULT_NAME_PREFIX} {n}"


def _parse_one(item: object, existing: Sequence[Device]) -> Optional[Device]:
    if not isinstance(item, dict):
        return None
    raw_id, kind, name = item.get("id"), item.get("kind"), item.get("name")
    if not isinstance(raw_id, str) or kind not in KINDS:
        return None
    device_id = normalize_id(raw_id)
    if not device_id or any(d.id == device_id for d in existing):
        return None
    try:
        name = clean_name(name) if isinstance(name, str) else ""
    except ValueError:
        name = ""
    return Device(device_id, name or default_name(existing), kind)


def parse_devices(raw: object) -> Tuple[Device, ...]:
    """從設定值還原裝置清單：丟棄格式錯誤的項目，id 重複只留第一筆。"""
    if not isinstance(raw, list):
        return ()
    devices: List[Device] = []
    for item in raw:
        device = _parse_one(item, devices)
        if device is not None:
            devices.append(device)
    return tuple(devices)


def serialize_devices(devices: Iterable[Device]) -> list:
    return [d.to_dict() for d in devices]


def add_devices(existing: Sequence[Device], new: Iterable[Device]) -> Tuple[Device, ...]:
    result = list(existing)
    for device in new:
        device_id = normalize_id(device.id)
        if any(d.id == device_id for d in result):
            continue
        result.append(Device(device_id, device.name, device.kind))
    return tuple(result)


def remove_device(existing: Sequence[Device], device_id: str) -> Tuple[Device, ...]:
    return tuple(d for d in existing if d.id != device_id)


def rename_device(existing: Sequence[Device], device_id: str, name: str) -> Tuple[Device, ...]:
    cleaned = clean_name(name)
    return tuple(Device(d.id, cleaned, d.kind) if d.id == device_id else d for d in existing)


def resolve_primary(devices: Sequence[Device], primary_id: Optional[str]) -> Optional[str]:
    """主裝置不在清單中時改用第一台；清單為空時為 None。"""
    if any(d.id == primary_id for d in devices):
        return primary_id
    return devices[0].id if devices else None


# MARK: - 遷移

@dataclass(frozen=True)
class MigrationPlan:
    devices: Tuple[Device, ...]
    primary_id: Optional[str]
    copy_history_to: Optional[str]  # 舊 history.json 要複製給哪一台
    legacy_unclaimed: bool          # 有舊歷史但沒有舊目標 (開源廣播用戶)


def plan_migration(devices_key_present: bool, legacy_target: object, legacy_history_exists: bool) -> Optional[MigrationPlan]:
    """決定遷移內容；已經遷移過 (設定中已有 Devices 鍵，即使是空清單) 時回傳 None。"""
    if devices_key_present:
        return None
    target = normalize_id(legacy_target) if isinstance(legacy_target, str) else ""
    if not target:
        return MigrationPlan((), None, None, legacy_history_exists)
    device = Device(target, f"{DEFAULT_NAME_PREFIX} 1", KIND_STOCK)
    return MigrationPlan((device,), target, target if legacy_history_exists else None, False)


def copy_without_overwrite(src: Path, dest: Path) -> bool:
    """複製檔案但絕不覆寫：先寫到暫存檔，再以 hard link 建立目的地 (已存在即放棄)。

    回傳是否真的建立了目的地；來源不存在或目的地已存在都回傳 False，其他 I/O 錯誤照常丟出。
    """
    if not src.is_file() or dest.exists():
        return False
    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dest.parent, prefix=f".{dest.name}.")
    try:
        with os.fdopen(fd, "wb") as out, open(src, "rb") as source:
            shutil.copyfileobj(source, out)
        try:
            os.link(tmp, dest)
        except FileExistsError:
            return False
        except OSError:
            return _exclusive_copy(tmp, dest)  # 檔案系統不支援硬連結
        return True
    finally:
        os.unlink(tmp)


def _exclusive_copy(src: Path, dest: Path) -> bool:
    """以排他模式建立目的地 (已存在即放棄)；寫到一半失敗會移除不完整的目的地。"""
    try:
        out = open(dest, "xb")
    except FileExistsError:
        return False
    try:
        with out, open(src, "rb") as source:
            shutil.copyfileobj(source, out)
    except BaseException:
        dest.unlink(missing_ok=True)
        raise
    return True


# MARK: - 持久化

class DeviceStore:
    """裝置清單與主裝置的保存 (透過與 settings.Settings 相同的 get/set 介面)。只在 GTK 主執行緒使用。"""

    def __init__(self, store, history_dir: Path, legacy_history: Path, settings_path: Optional[Path] = None):
        self._store = store
        self._history_dir = history_dir
        self._legacy_history = legacy_history
        self._settings_path = settings_path
        self._devices: Tuple[Device, ...] = ()
        self._primary_id: Optional[str] = None
        self._reload()

    def _reload(self) -> None:
        self._devices = parse_devices(self._store.get(DEVICES_KEY))
        primary = self._store.get(PRIMARY_KEY)
        self._primary_id = resolve_primary(self._devices, primary if isinstance(primary, str) else None)

    @property
    def devices(self) -> Tuple[Device, ...]:
        return self._devices

    @property
    def primary_id(self) -> Optional[str]:
        return self._primary_id

    def get(self, device_id: Optional[str]) -> Optional[Device]:
        return next((d for d in self._devices if d.id == device_id), None)

    def ordered_ids(self) -> List[str]:
        """主裝置排第一，其餘照清單順序 (輪詢時主裝置優先)。"""
        ids = [d.id for d in self._devices]
        if self._primary_id in ids:
            ids.remove(self._primary_id)
            ids.insert(0, self._primary_id)
        return ids

    def history_path(self, device_id: str) -> Path:
        return history_path_for(device_id, self._history_dir)

    # 遷移

    def migrate(self) -> bool:
        """把舊版單一裝置設定轉成裝置清單；回傳是否執行了遷移。"""
        plan = plan_migration(
            self._store.get(DEVICES_KEY, _MISSING) is not _MISSING,
            self._store.get(LEGACY_TARGET_KEY),
            self._legacy_history.is_file(),
        )
        if plan is None:
            return False
        self._backup_settings()
        if plan.copy_history_to is not None:
            # 複製失敗 (I/O 錯誤) 時直接丟出，不寫 Devices，下次啟動會再試
            copied = copy_without_overwrite(self._legacy_history, self.history_path(plan.copy_history_to))
            mijia_log(f"遷移: 舊歷史{'已複製' if copied else '未複製 (目的地已存在)'}到 {plan.copy_history_to}")
        self._migrate_low_battery_time(plan.primary_id)
        if plan.legacy_unclaimed:
            self._store.set(LEGACY_UNCLAIMED_KEY, True)
        self._store.set(PRIMARY_KEY, plan.primary_id)
        # Devices 最後寫入，作為遷移完成的記號
        self._store.set(DEVICES_KEY, serialize_devices(plan.devices))
        self._reload()
        mijia_log(f"遷移完成: {len(plan.devices)} 台裝置，主裝置 {plan.primary_id}")
        return True

    def _backup_settings(self) -> None:
        if self._settings_path is None:
            return
        try:
            copy_without_overwrite(self._settings_path, self._settings_path.with_name(SETTINGS_BACKUP_NAME))
        except OSError as e:
            mijia_log(f"遷移: 無法備份設定檔: {e}")

    def _migrate_low_battery_time(self, device_id: Optional[str]) -> None:
        last = self._store.get(LEGACY_LOW_BATTERY_KEY)
        if device_id is None or self._store.get(LOW_BATTERY_TIMES_KEY) is not None:
            return
        if isinstance(last, (int, float)) and not isinstance(last, bool):
            self._store.set(LOW_BATTERY_TIMES_KEY, {device_id: float(last)})

    # 清單操作

    def add(self, new_devices: Sequence[Device]) -> Tuple[Device, ...]:
        """加入新裝置 (已存在的略過)，回傳實際加入的裝置。"""
        before = {d.id for d in self._devices}
        devices = add_devices(self._devices, new_devices)
        added = tuple(d for d in devices if d.id not in before)
        if added and self._store.get(LEGACY_UNCLAIMED_KEY) is True:
            self._claim_legacy_history(added[0].id)
        self._save(devices, self._primary_id)
        return added

    def _claim_legacy_history(self, device_id: str) -> None:
        try:
            copy_without_overwrite(self._legacy_history, self.history_path(device_id))
        except OSError as e:
            mijia_log(f"無法把舊歷史複製給 {device_id}: {e}")
            return
        self._store.set(LEGACY_UNCLAIMED_KEY, False)
        mijia_log(f"舊歷史已交給第一台加入的裝置 {device_id}")

    def remove(self, device_id: str) -> None:
        """只從清單移除；該裝置的歷史檔保留在磁碟上。"""
        self._save(remove_device(self._devices, device_id), self._primary_id)

    def rename(self, device_id: str, name: str) -> None:
        self._save(rename_device(self._devices, device_id, name), self._primary_id)

    def set_primary(self, device_id: str) -> None:
        if self.get(device_id) is not None:
            self._save(self._devices, device_id)

    def _save(self, devices: Tuple[Device, ...], primary_id: Optional[str]) -> None:
        primary = resolve_primary(devices, primary_id)
        self._store.set(DEVICES_KEY, serialize_devices(devices))
        self._store.set(PRIMARY_KEY, primary)
        self._devices, self._primary_id = devices, primary
