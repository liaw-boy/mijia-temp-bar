"""狀態 JSON (給外部腳本讀取)：頂層欄位維持舊格式代表主裝置，另加每台裝置的 devices 陣列。"""

import json
from pathlib import Path
from typing import Mapping, Optional, Sequence

from .device_state import DeviceState
from .devices import Device
from .settings import RUNTIME_DIR, atomic_write_text

STATUS_JSON_PATH = RUNTIME_DIR / "mijia_status.json"


def _device_entry(device: Device, state: DeviceState, primary: bool) -> dict:
    entry = {
        "id": device.id,
        "name": device.name,
        "kind": device.kind,
        "primary": primary,
        "reachable": state.reachable,
        "status": state.status,
    }
    r = state.reading
    if r is not None:
        entry.update(
            temperature=r.temperature,
            humidity=r.humidity,
            batteryPercent=r.battery_percent,
            voltage=r.voltage,
            mode=r.mode,
            lastUpdated=r.last_updated.isoformat(timespec="seconds"),
        )
    return entry


def build_status_payload(devices: Sequence[Device], states: Mapping[str, DeviceState], primary_id: Optional[str],
                         interval: float, timestamp: str, adapter_status: Optional[str] = None) -> dict:
    primary = next((d for d in devices if d.id == primary_id), None)
    primary_state = states.get(primary_id, DeviceState()) if primary else None

    if adapter_status:
        status = adapter_status
    elif primary_state is not None:
        status = primary_state.status
    else:
        status = "尚未加入裝置"

    payload = {"status": status, "timestamp": timestamp, "refreshIntervalSeconds": int(interval)}
    if primary is not None and primary_state is not None and primary_state.reading is not None:
        r = primary_state.reading
        payload.update(
            temperature=r.temperature,
            humidity=r.humidity,
            batteryPercent=r.battery_percent,
            voltage=r.voltage,
            deviceName=primary.name,
            mode=r.mode,
        )
    payload["primaryDeviceId"] = primary_id
    payload["devices"] = [_device_entry(d, states.get(d.id, DeviceState()), d.id == primary_id) for d in devices]
    return payload


def write_status_json(payload: dict, path: Path = STATUS_JSON_PATH) -> None:
    try:
        atomic_write_text(path, json.dumps(payload, ensure_ascii=False, indent=2))
    except OSError:
        pass
