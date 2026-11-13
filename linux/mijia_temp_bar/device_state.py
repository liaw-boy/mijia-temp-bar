"""每台裝置的即時狀態與顯示規則 (純邏輯，可單元測試)。"""

from dataclasses import dataclass, replace
from typing import Mapping, Optional, Sequence, Tuple

from .parsers import SensorReading

STATUS_OK = "正常運作中"
STATUS_WAITING = "等待讀取"


@dataclass(frozen=True)
class DeviceState:
    reading: Optional[SensorReading] = None
    reachable: Optional[bool] = None  # None = 尚未確認 (例如啟動時使用歷史快取)
    status: str = STATUS_WAITING
    cached: bool = False              # 讀數來自上次的歷史紀錄，不是這次連線讀到的


def with_reading(state: DeviceState, reading: SensorReading) -> DeviceState:
    return DeviceState(reading=reading, reachable=True, status=STATUS_OK, cached=False)


def with_status(state: DeviceState, status: str, reachable: Optional[bool]) -> DeviceState:
    """更新狀態文字；reachable 為 None 表示可連線與否沒有改變。"""
    return replace(state, status=status, reachable=state.reachable if reachable is None else reachable)


def should_hide_icon(hide_enabled: bool, device_ids: Sequence[str], states: Mapping[str, DeviceState]) -> bool:
    """「僅連線時顯示」：只有全部裝置都確定連不到才隱藏；沒有任何裝置時不隱藏 (才能加入裝置)。"""
    if not hide_enabled or not device_ids:
        return False
    return all(device_id in states and states[device_id].reachable is False for device_id in device_ids)


def display_device_id(primary_id: Optional[str], ordered_ids: Sequence[str],
                      states: Mapping[str, DeviceState]) -> Optional[str]:
    """狀態列要顯示哪一台 (帶筆電換地方時用)。

    主裝置可連線或尚未確認 → 主裝置；主裝置連不到但有別台在附近 → 最近讀到的那台
    (不改使用者選的主裝置，回到主裝置附近就換回來)；都連不到 → 仍是主裝置 (畫成 -- 或依設定隱藏)。
    """
    if primary_id is None:
        return None
    primary = states.get(primary_id)
    if primary is None or primary.reachable is not False:
        return primary_id
    nearby = [
        device_id for device_id in ordered_ids
        if device_id != primary_id and device_id in states
        and states[device_id].reachable is True and states[device_id].reading is not None
    ]
    if not nearby:
        return primary_id
    return max(nearby, key=lambda device_id: states[device_id].reading.last_updated)


def tray_values(state: Optional[DeviceState]) -> Tuple[Optional[float], Optional[float]]:
    """主裝置要顯示在狀態列的 (溫度, 濕度)；連不到時回傳 (None, None) 以顯示 --。"""
    if state is None or state.reading is None or state.reachable is False:
        return None, None
    return state.reading.temperature, state.reading.humidity


def summary_text(name: str, state: DeviceState) -> str:
    """選單中每台裝置的一行摘要。"""
    if state.reading is None and state.reachable is not False:
        return f"{name} · {state.status}"
    temp, hum = tray_values(state)
    if temp is None or hum is None:
        return f"{name} · -- ({state.status})"
    return f"{name} · {temp:.1f}° · {hum:.0f}%"
