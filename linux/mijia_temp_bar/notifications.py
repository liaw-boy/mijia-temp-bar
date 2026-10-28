"""低電量通知：判斷邏輯為純函式 (可單元測試)，發送透過 Gio.Notification。"""

from typing import Optional

from .logger import mijia_log
from .parsers import SensorReading
from .settings import settings

LOW_BATTERY_PERCENT = 15
LOW_VOLTAGE = 2.60
RECOVERED_PERCENT = 30           # 換新電池後 (電量回升到此值以上) 重置冷卻
COOLDOWN_SECONDS = 24 * 3600     # 24 小時內不重複提醒

ENABLED_KEY = "LowBatteryNotificationEnabled"
LAST_ALERT_KEY = "LastLowBatteryNotificationTime"


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


def check_reading(app, reading: SensorReading, now: float) -> None:
    """依讀數決定是否發出通知；app 為 Gtk.Application。"""
    if not is_enabled():
        return
    last = settings.get(LAST_ALERT_KEY)
    last = float(last) if isinstance(last, (int, float)) else None

    if not is_low(reading.battery_percent, reading.voltage):
        if reading.battery_percent > RECOVERED_PERCENT and last is not None:
            settings.set(LAST_ALERT_KEY, None)
        return
    if not should_alert(reading.battery_percent, reading.voltage, last, now):
        return

    from gi.repository import Gio

    note = Gio.Notification.new("米家溫濕度計 2 - 低電量提醒")
    note.set_body(
        f"目前電量剩 {reading.battery_percent}% ({reading.voltage:.3f} V)，"
        "建議盡快更換 CR2032 鈕扣電池。"
    )
    app.send_notification("low-battery", note)
    settings.set(LAST_ALERT_KEY, now)
    mijia_log(f"[Notification] 低電量通知: {reading.battery_percent}%, {reading.voltage:.3f}V")
