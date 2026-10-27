"""原廠 GATT 數據與開源韌體 (ATC / pvvx / BTHome) 廣播解析。

全部為純函式，不依賴藍牙堆疊，方便單元測試。
"""

from dataclasses import dataclass
from datetime import datetime
from typing import NamedTuple, Optional

MODE_STOCK = "原廠直連 (即連即斷省電模式)"
MODE_ATC = "開源 ATC 廣播"
MODE_PVVX = "開源 pvvx 廣播"
MODE_BTHOME = "BTHome 廣播"


@dataclass
class SensorReading:
    temperature: float      # 攝氏度 (°C)
    humidity: float         # 相對濕度 (%)
    battery_percent: int    # 電量百分比 (0-100%)
    voltage: float          # 電池電壓 (V)
    rssi: Optional[int]     # 訊號強度 (dBm)
    device_name: str        # 設備名稱
    last_updated: datetime  # 最後更新時間
    mode: str               # 原廠模式 / 開源廣播模式
    is_broadcast: bool = False


class Measurement(NamedTuple):
    temperature: float
    humidity: float
    battery_percent: int
    voltage: float
    mode: str


def battery_from_voltage(volt: float) -> int:
    """CR2032 鈕扣電池：2.1V 視為 0%，3.0V 視為 100%。"""
    return min(100, max(0, int((volt - 2.1) / (3.0 - 2.1) * 100.0)))


def _is_plausible(temp: float, hum: float) -> bool:
    return -30.0 <= temp <= 70.0 and 0.0 <= hum <= 100.0


def parse_stock_gatt(data: bytes) -> Optional[Measurement]:
    """原廠韌體 Characteristic EBE0CCC1：int16 溫度 (0.01°C) + uint8 濕度 + uint16 電壓 (mV)，皆為 little-endian。"""
    if len(data) < 5:
        return None
    temp = int.from_bytes(data[0:2], "little", signed=True) / 100.0
    hum = float(data[2])
    volt = int.from_bytes(data[3:5], "little") / 1000.0
    return Measurement(temp, hum, battery_from_voltage(volt), volt, MODE_STOCK)


def _parse_atc1441(data: bytes) -> Optional[Measurement]:
    """ATC1441 格式 (13 bytes, big-endian)：MAC[6] 溫度 int16 (0.1°C) 濕度 uint8 電量 uint8 電壓 uint16 (mV) 計數。"""
    if len(data) < 10:
        return None
    temp = int.from_bytes(data[6:8], "big", signed=True) / 10.0
    hum = float(data[8])
    bat = int(data[9])
    volt = int.from_bytes(data[10:12], "big") / 1000.0 if len(data) >= 12 else 3.0
    if not _is_plausible(temp, hum):
        return None
    return Measurement(temp, hum, bat, volt, MODE_ATC)


def _parse_pvvx(data: bytes) -> Optional[Measurement]:
    """pvvx 自訂格式 (15 bytes, little-endian)：MAC[6] 溫度 int16 (0.01°C) 濕度 uint16 (0.01%) 電壓 uint16 (mV) 電量 uint8 ..."""
    if len(data) < 13:
        return None
    temp = int.from_bytes(data[6:8], "little", signed=True) / 100.0
    hum = int.from_bytes(data[8:10], "little") / 100.0
    volt = int.from_bytes(data[10:12], "little") / 1000.0
    bat = int(data[12])
    if not _is_plausible(temp, hum):
        return None
    return Measurement(temp, hum, bat, volt, MODE_PVVX)


def parse_environmental_service_data(data: bytes) -> Optional[Measurement]:
    """Service Data UUID 0x181A：依長度優先嘗試對應格式 (pvvx 為 15 bytes、ATC1441 為 13 bytes)。"""
    parsers = (_parse_pvvx, _parse_atc1441) if len(data) >= 15 else (_parse_atc1441, _parse_pvvx)
    for parse in parsers:
        result = parse(data)
        if result is not None:
            return result
    return None


# BTHome v2 物件 ID -> 資料長度 (bytes)，僅列出溫濕度計韌體會用到的物件
_BTHOME_OBJECT_SIZES = {
    0x00: 1,  # packet id
    0x01: 1,  # battery (%)
    0x02: 2,  # temperature (sint16, 0.01 °C)
    0x03: 2,  # humidity (uint16, 0.01 %)
    0x0C: 2,  # voltage (uint16, 0.001 V)
    0x0F: 1,  # generic boolean
    0x10: 1,  # power
    0x11: 1,  # opening
    0x2E: 1,  # humidity (uint8, 1 %)
    0x3A: 1,  # button
    0x45: 2,  # temperature (sint16, 0.1 °C)
}


def parse_bthome(data: bytes) -> Optional[Measurement]:
    """Service Data UUID 0xFCD2 (BTHome v2，僅支援未加密)。"""
    if len(data) < 5:
        return None
    if data[0] & 0x01:
        return None  # 加密封包需要 bindkey，不處理

    temp: Optional[float] = None
    hum: Optional[float] = None
    bat: Optional[int] = None
    volt: Optional[float] = None

    index = 1
    while index < len(data):
        object_id = data[index]
        size = _BTHOME_OBJECT_SIZES.get(object_id)
        if size is None or index + 1 + size > len(data):
            break  # 未知物件無法得知長度，停止解析
        value = data[index + 1:index + 1 + size]
        if object_id == 0x01:
            bat = value[0]
        elif object_id == 0x02:
            temp = int.from_bytes(value, "little", signed=True) * 0.01
        elif object_id == 0x45:
            temp = int.from_bytes(value, "little", signed=True) * 0.1
        elif object_id == 0x03:
            hum = int.from_bytes(value, "little") * 0.01
        elif object_id == 0x2E:
            hum = float(value[0])
        elif object_id == 0x0C:
            volt = int.from_bytes(value, "little") * 0.001
        index += 1 + size

    if temp is None or hum is None:
        return None
    return Measurement(
        round(temp, 2),
        round(hum, 2),
        bat if bat is not None else 100,
        round(volt, 3) if volt is not None else 3.0,
        MODE_BTHOME,
    )
