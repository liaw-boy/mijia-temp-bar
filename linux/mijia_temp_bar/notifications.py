"""低電量與濕度通知 (每台裝置各自計算)：判斷邏輯為純函式 (可單元測試)，發送透過 Gio.Notification。"""

from typing import Dict, Optional, Tuple

from .devices import LOW_BATTERY_TIMES_KEY, file_id
from .logger import mijia_log
from .parsers import SensorReading
from .settings import settings

LOW_BATTERY_PERCENT = 15
LOW_VOLTAGE = 2.60
RECOVERED_PERCENT = 30           # 換新電池後 (電量回升到此值以上) 重置冷卻
COOLDOWN_SECONDS = 24 * 3600     # 24 小時內不重複提醒

HUMIDITY_REPEAT_SECONDS = 3 * 3600  # 持續超標時的再次提醒間隔
HUMIDITY_HYSTERESIS = 2.0           # 回到範圍內再多 2% 才重新武裝，避免在門檻附近來回觸發
DEFAULT_HUMIDITY_HIGH = 70
DEFAULT_HUMIDITY_LOW = 30

HUMIDITY_ENABLED_KEY = "HumidityAlertEnabled"
HUMIDITY_HIGH_KEY = "HumidityHighThreshold"
HUMIDITY_LOW_KEY = "HumidityLowThreshold"
ENABLED_KEY = "LowBatteryNotificationEnabled"


def is_low(battery_percent: int, voltage: float) -> bool:
    return battery_percent <= LOW_BATTERY_PERCENT or voltage <= LOW_VOLTAGE


def should_alert(battery_percent: int, voltage: float, last_alert: Optional[float], now: float) -> bool:
    if not is_low(battery_percent, voltage):
        return False
    return last_alert is None or now - last_alert >= COOLDOWN_SECONDS


def is_enabled() -> bool:
    value = settings.get(ENABLED_KEY)
    return value if isinstance(value, bool) else True


def set_enabled(enabled: bool) -> None:
    settings.set(ENABLED_KEY, enabled)


def next_low_battery_state(last_alert: Optional[float], battery_percent: int, voltage: float,
                           now: float) -> Tuple[bool, Optional[float]]:
    """回傳 (是否通知, 新的上次通知時間)；電量回升到 30% 以上 (換新電池) 時清除冷卻。"""
    if not is_low(battery_percent, voltage):
        return False, (None if battery_percent > RECOVERED_PERCENT else last_alert)
    if should_alert(battery_percent, voltage, last_alert, now):
        return True, now
    return False, last_alert


def _low_battery_times() -> Dict[str, float]:
    raw = settings.get(LOW_BATTERY_TIMES_KEY)
    if not isinstance(raw, dict):
        return {}
    return {k: float(v) for k, v in raw.items()
            if isinstance(k, str) and isinstance(v, (int, float)) and not isinstance(v, bool)}


def check_reading(app, device_id: str, device_name: str, reading: SensorReading, now: float) -> None:
    """依讀數決定是否發出這台裝置的低電量通知；app 為 Gtk.Application。"""
    if not is_enabled():
        return
    times = _low_battery_times()
    last = times.get(device_id)
    notify, new_last = next_low_battery_state(last, reading.battery_percent, reading.voltage, now)
    if new_last != last:
        updated = {k: v for k, v in times.items() if k != device_id}
        if new_last is not None:
            updated[device_id] = new_last
        settings.set(LOW_BATTERY_TIMES_KEY, updated)
    if not notify:
        return

    from gi.repository import Gio

    note = Gio.Notification.new(f"{device_name} - 低電量提醒")
    note.set_body(
        f"{device_name} 目前電量剩 {reading.battery_percent}% ({reading.voltage:.3f} V)，"
        "建議盡快更換 CR2032 鈕扣電池。"
    )
    app.send_notification(f"low-battery-{file_id(device_id)}", note)
    mijia_log(f"[Notification] 低電量通知 [{device_id}]: {reading.battery_percent}%, {reading.voltage:.3f}V")


class HumidityMonitor:
    """濕度上下限警示的狀態機 (純邏輯)：進入超標狀態通知一次，持續超標每 3 小時再提醒。"""

    def __init__(self) -> None:
        self._state = "normal"  # "normal" | "high" | "low"
        self._last_alert: Optional[float] = None

    def reset(self) -> None:
        self._state = "normal"
        self._last_alert = None

    def check(self, humidity: float, high: float, low: float, now: float) -> Optional[str]:
        """回傳 "high" / "low" 表示此刻應通知，None 表示不通知。"""
        current = "high" if humidity > high else ("low" if humidity < low else "normal")
        if current == "normal":
            if low + HUMIDITY_HYSTERESIS <= humidity <= high - HUMIDITY_HYSTERESIS:
                self.reset()
            return None

        new_excursion = current != self._state
        repeat_due = self._last_alert is None or now - self._last_alert >= HUMIDITY_REPEAT_SECONDS
        if not (new_excursion or repeat_due):
            return None
        self._state = current
        self._last_alert = now
        return current


def valid_thresholds(high: int, low: int) -> bool:
    return 0 <= low < high <= 100


def humidity_enabled() -> bool:
    value = settings.get(HUMIDITY_ENABLED_KEY)
    return value if isinstance(value, bool) else False  # 預設關閉


def set_humidity_enabled(enabled: bool) -> None:
    settings.set(HUMIDITY_ENABLED_KEY, enabled)


def humidity_thresholds() -> Tuple[int, int]:
    """(上限, 下限)；設定檔內容不合法時回到預設值。"""
    high = settings.get(HUMIDITY_HIGH_KEY)
    low = settings.get(HUMIDITY_LOW_KEY)
    if (isinstance(high, int) and not isinstance(high, bool)
            and isinstance(low, int) and not isinstance(low, bool)
            and valid_thresholds(high, low)):
        return high, low
    return DEFAULT_HUMIDITY_HIGH, DEFAULT_HUMIDITY_LOW


def set_humidity_thresholds(high: int, low: int) -> bool:
    if not valid_thresholds(high, low):
        return False
    settings.set(HUMIDITY_HIGH_KEY, high)
    settings.set(HUMIDITY_LOW_KEY, low)
    return True


_monitors: Dict[str, HumidityMonitor] = {}


def humidity_monitor_for(device_id: str) -> HumidityMonitor:
    monitor = _monitors.get(device_id)
    if monitor is None:
        monitor = HumidityMonitor()
        _monitors[device_id] = monitor
    return monitor


def reset_humidity_monitor() -> None:
    """門檻或開關變更時，所有裝置重新開始判斷。"""
    _monitors.clear()


def check_humidity(app, device_id: str, device_name: str, reading: SensorReading, now: float) -> None:
    """依讀數決定是否發出這台裝置的濕度通知；app 為 Gtk.Application。"""
    if not humidity_enabled():
        return
    high, low = humidity_thresholds()
    result = humidity_monitor_for(device_id).check(reading.humidity, high, low, now)
    if result is None:
        return

    from gi.repository import Gio

    if result == "high":
        title = f"{device_name} - 濕度過高"
        body = f"{device_name} 目前濕度 {reading.humidity:.0f}%，高於設定的上限 {high}%。"
    else:
        title = f"{device_name} - 濕度過低"
        body = f"{device_name} 目前濕度 {reading.humidity:.0f}%，低於設定的下限 {low}%。"
    note = Gio.Notification.new(title)
    note.set_body(body)
    app.send_notification(f"humidity-{file_id(device_id)}", note)
    mijia_log(f"[Notification] 濕度警示 [{device_id}]: {body}")
