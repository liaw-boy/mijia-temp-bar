"""換地方偵測：電腦從睡眠喚醒或網路變動 (例如換了 Wi-Fi) 時，通知所有裝置立刻重讀一次。

帶筆電移動時，原本那台會連不到、新地方那台會連上，狀態列就能改顯示附近那台，
不必等到下一次輪詢 (間隔可能長達數小時)。
"""

import time
from typing import Callable, Optional

from gi.repository import Gio, GLib

from .logger import mijia_log

DEBOUNCE_SECONDS = 5      # 網路變動常會連續觸發多次，合併成一次
MIN_GAP_SECONDS = 60.0    # 兩次重新偵測至少間隔 60 秒


class ReprobeTriggers:
    def __init__(self, on_trigger: Callable[[str], None]):
        self._on_trigger = on_trigger
        self._pending: Optional[int] = None
        self._pending_reason = ""
        self._last = 0.0
        self._sleep_subscription: Optional[int] = None
        self._system_bus = None
        self._subscribe_sleep()
        try:
            Gio.NetworkMonitor.get_default().connect("network-changed", self._on_network_changed)
        except GLib.Error as e:
            mijia_log(f"無法監看網路變動: {e.message}")

    def _subscribe_sleep(self) -> None:
        """systemd-logind 的 PrepareForSleep(false) = 剛從睡眠喚醒。"""
        try:
            self._system_bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        except GLib.Error as e:
            mijia_log(f"無法連線系統匯流排，喚醒時不會自動重新偵測: {e.message}")
            return
        self._sleep_subscription = self._system_bus.signal_subscribe(
            "org.freedesktop.login1", "org.freedesktop.login1.Manager", "PrepareForSleep",
            "/org/freedesktop/login1", None, Gio.DBusSignalFlags.NONE, self._on_prepare_for_sleep,
        )

    def _on_prepare_for_sleep(self, _conn, _sender, _path, _iface, _signal, params) -> None:
        going_to_sleep = params.unpack()[0]
        if not going_to_sleep:
            self._schedule("從睡眠喚醒")

    def _on_network_changed(self, _monitor, _available) -> None:
        self._schedule("網路變動")

    def _schedule(self, reason: str) -> None:
        self._pending_reason = reason
        if self._pending is None:
            self._pending = GLib.timeout_add_seconds(DEBOUNCE_SECONDS, self._fire)

    def _fire(self) -> bool:
        self._pending = None
        now = time.monotonic()
        if now - self._last >= MIN_GAP_SECONDS:
            self._last = now
            self._on_trigger(self._pending_reason)
        return GLib.SOURCE_REMOVE
