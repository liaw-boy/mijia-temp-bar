"""換地方偵測：電腦從睡眠喚醒、或換到另一個網路 (預設閘道不同) 時，通知所有裝置立刻重讀一次。

帶筆電移動時，原本那台會連不到、新地方那台會連上，狀態列就能改顯示附近那台，
不必等到下一次輪詢 (間隔可能長達數小時)。網路變動通知很頻繁 (VPN、Docker 等虛擬介面)，
比對預設閘道後只在真的換網路時觸發，避免多耗溫濕度計的電池。
"""

import time
from typing import Callable, Optional

from gi.repository import Gio, GLib

from .logger import mijia_log
from .network_signature import (
    ReprobeGate,
    after_network_change,
    after_pending_due,
    after_wake,
    pending_due_at,
    read_signature,
)

DEBOUNCE_SECONDS = 5      # 網路變動常會連續觸發多次，合併成一次
MAC_RETRY_SECONDS = 3     # 剛換網路時閘道硬體位址可能還沒查到，等幾秒再讀一次
NETWORK_REASON = "換到另一個網路"


class ReprobeTriggers:
    def __init__(self, on_trigger: Callable[[str], None]):
        self._on_trigger = on_trigger
        self._pending: Optional[int] = None
        self._pending_wake = False
        self._pending_move_source: Optional[int] = None
        self._sleep_subscription: Optional[int] = None
        self._system_bus = None
        # 記下啟動時的網路當作比對基準 (第一次只記錄，不觸發)
        self._gate, _ = after_network_change(ReprobeGate(), read_signature(), time.monotonic())
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
            self._pending_wake = True
            self._schedule()

    def _on_network_changed(self, _monitor, _available) -> None:
        self._schedule()

    def _schedule(self) -> None:
        if self._pending is None:
            self._pending = GLib.timeout_add_seconds(DEBOUNCE_SECONDS, self._fire)

    def _fire(self) -> bool:
        self._pending = None
        if self._pending_wake:
            self._pending_wake = False
            self._gate, fired = after_wake(self._gate, time.monotonic())
            if fired:
                self._on_trigger("從睡眠喚醒")
        # 每次都比對網路 (喚醒後也要更新記錄)；讀 /proc 很快，不必放到背景
        self._check_network(True)
        return GLib.SOURCE_REMOVE

    def _check_network(self, allow_retry: bool) -> bool:
        current = read_signature()
        if allow_retry and current.known and current.gateway_mac is None:
            GLib.timeout_add_seconds(MAC_RETRY_SECONDS, self._check_network, False)
            return GLib.SOURCE_REMOVE
        self._gate, fired = after_network_change(self._gate, current, time.monotonic())
        if fired:
            self._on_trigger(NETWORK_REASON)
        self._schedule_pending_move()
        return GLib.SOURCE_REMOVE

    def _schedule_pending_move(self) -> None:
        """保底間隔內又換了網路：間隔到了補讀一次。"""
        due = pending_due_at(self._gate)
        if due is None or self._pending_move_source is not None:
            return
        delay = max(1, int(due - time.monotonic()) + 1)
        self._pending_move_source = GLib.timeout_add_seconds(delay, self._fire_pending_move)

    def _fire_pending_move(self) -> bool:
        self._pending_move_source = None
        self._gate, fired = after_pending_due(self._gate, time.monotonic())
        if fired:
            self._on_trigger(NETWORK_REASON)
        else:
            self._schedule_pending_move()
        return GLib.SOURCE_REMOVE
